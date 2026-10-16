#include <stdint.h>
#ifndef _MSC_VER
  #include <string.h>
#endif

#define KB_TEXT_SHAPE_NO_CRT
#define KB_TEXT_SHAPE_IMPLEMENTATION
#include "kb_text_shape.h"

// Added for TIDALfast: kb_text_shape's Unicode bidi class table, which the
// library doesn't export. Returns a kbts_unicode_bidirectional_class.
int tidalfast_bidi_class(int Codepoint)
{
  return kbts__GetUnicodeBidirectionalClass((kbts_u32)Codepoint);
}
// Added for TIDALfast: copies a blob that kbts_PlaceBlob made into Output,
// smaller. The glyph lookup matrices keep a bit for every glyph in every
// lookup and subtable, 3.4 MB for a big CJK font, and nearly all of it is
// zeros: the copy keeps each row as blocks of KBTS__MATRIX_BLOCK_BITS
// glyphs, with all the empty blocks sharing one. The vertical metrics are
// left out, since kb_text_shape lays out horizontally only. Returns the
// size Output needs, writing nothing when Output is null, or 0 when the
// blob has nothing to compact. Output must not overlap Blob and must be
// aligned like malloc's memory.
static kbts_un tidalfast_compact_matrix(kbts_u32 *Matrix, kbts_un RowCount, kbts_un GlyphCount, kbts_u16 *Blocks, kbts_u32 *Words, kbts_un BlockCount)
{
  kbts_un BlocksPerRow = (GlyphCount + KBTS__MATRIX_BLOCK_BITS - 1) / KBTS__MATRIX_BLOCK_BITS;
  kbts_un MatrixWords = (RowCount * GlyphCount + 31) / 32;
  KBTS__FOR(Row, 0, RowCount)
  {
    KBTS__FOR(Block, 0, BlocksPerRow)
    {
      kbts_u32 Bits[KBTS__MATRIX_BLOCK_WORDS] = {0};
      kbts_u32 Any = 0;
      KBTS__FOR(Word, 0, KBTS__MATRIX_BLOCK_WORDS)
      {
        // The 32 glyphs from FirstGlyph, which may straddle two words of the
        // dense matrix, whose rows are packed bit to bit.
        kbts_un FirstGlyph = Block * KBTS__MATRIX_BLOCK_BITS + Word * 32;
        if(FirstGlyph >= GlyphCount)
        {
          break;
        }
        kbts_un Bit = Row * GlyphCount + FirstGlyph;
        kbts_un Shift = Bit % 32;
        kbts_u32 Value = Matrix[Bit / 32] >> Shift;
        if(Shift && (Bit / 32 + 1 < MatrixWords))
        {
          Value |= Matrix[Bit / 32 + 1] << (32 - Shift);
        }
        if(GlyphCount - FirstGlyph < 32)
        {
          Value &= (1u << (GlyphCount - FirstGlyph)) - 1;
        }
        Bits[Word] = Value;
        Any |= Value;
      }
      kbts_un Index = 0;
      if(Any)
      {
        Index = BlockCount;
        BlockCount += 1;
        if(Words)
        {
          KBTS_MEMCPY(Words + Index * KBTS__MATRIX_BLOCK_WORDS, Bits, sizeof(Bits));
        }
      }
      if(Blocks)
      {
        Blocks[Row * BlocksPerRow + Block] = (kbts_u16)Index;
      }
    }
  }
  return BlockCount;
}

int tidalfast_compact_blob(void *Blob, void *Output)
{
  kbts_blob_header *Header = (kbts_blob_header *)Blob;
  if(Header->Magic != KBTS_FOURCC('k', 'b', 't', 's') || Header->MatrixBlocksOffsetFromStartOfFile ||
     !Header->GlyphLookupMatrixOffsetFromStartOfFile || !Header->GlyphCount)
  {
    return 0;
  }
  kbts_un LookupCount = Header->LookupCount;
  kbts_un SubtableCount = Header->LookupSubtableCount;
  kbts_un GlyphCount = Header->GlyphCount;
  kbts_un BlocksPerRow = (GlyphCount + KBTS__MATRIX_BLOCK_BITS - 1) / KBTS__MATRIX_BLOCK_BITS;
  kbts_u32 *LookupMatrix = KBTS__POINTER_OFFSET(kbts_u32, Header, Header->GlyphLookupMatrixOffsetFromStartOfFile);
  kbts_u32 *SubtableMatrix = KBTS__POINTER_OFFSET(kbts_u32, Header, Header->GlyphLookupSubtableMatrixOffsetFromStartOfFile);
  kbts_u32 *IndexOffsets = KBTS__POINTER_OFFSET(kbts_u32, Header, Header->LookupSubtableIndexOffsetsOffsetFromStartOfFile);

  // Block 0 is the shared empty one.
  kbts_un BlockCount = tidalfast_compact_matrix(LookupMatrix, LookupCount, GlyphCount, 0, 0, 1);
  BlockCount = tidalfast_compact_matrix(SubtableMatrix, SubtableCount, GlyphCount, 0, 0, BlockCount);
  if(BlockCount > 0x10000)
  {
    return 0;
  }

  kbts_blob_header *Out = (kbts_blob_header *)Output;
  kbts_un At = sizeof(kbts_blob_header);
  if(Out) *Out = *Header;
  KBTS__FOR(TableId, 0, KBTS_BLOB_TABLE_ID_COUNT)
  {
    kbts_blob_table Table = Header->Tables[TableId];
    if((TableId == KBTS_BLOB_TABLE_ID_VHEA) || (TableId == KBTS_BLOB_TABLE_ID_VMTX) || !Table.Length)
    {
      Table.OffsetFromStartOfFile = 0;
      Table.Length = 0;
    }
    else
    {
      At = (At + 3) & ~(kbts_un)3;
      if(Out) KBTS_MEMCPY((char *)Out + At, (char *)Header + Table.OffsetFromStartOfFile, Table.Length);
      Table.OffsetFromStartOfFile = (kbts_u32)At;
      At += Table.Length;
    }
    if(Out) Out->Tables[TableId] = Table;
  }
  At = (At + 3) & ~(kbts_un)3;
  kbts_un IndexOffsetsAt = At;
  At += LookupCount * sizeof(kbts_u32);
  kbts_un WordsAt = At;
  At += BlockCount * KBTS__MATRIX_BLOCK_WORDS * sizeof(kbts_u32);
  kbts_un BlocksAt = At;
  At += (LookupCount + SubtableCount) * BlocksPerRow * sizeof(kbts_u16);

  if(Out)
  {
    kbts_u32 *Words = KBTS__POINTER_OFFSET(kbts_u32, Out, WordsAt);
    kbts_u16 *Blocks = KBTS__POINTER_OFFSET(kbts_u16, Out, BlocksAt);
    KBTS_MEMSET(Words, 0, KBTS__MATRIX_BLOCK_WORDS * sizeof(kbts_u32));
    kbts_un Count = tidalfast_compact_matrix(LookupMatrix, LookupCount, GlyphCount, Blocks, Words, 1);
    tidalfast_compact_matrix(SubtableMatrix, SubtableCount, GlyphCount, Blocks + LookupCount * BlocksPerRow, Words, Count);
    KBTS_MEMCPY((char *)Out + IndexOffsetsAt, IndexOffsets, LookupCount * sizeof(kbts_u32));
    Out->LookupSubtableIndexOffsetsOffsetFromStartOfFile = (kbts_u32)IndexOffsetsAt;
    Out->GlyphLookupMatrixOffsetFromStartOfFile = (kbts_u32)WordsAt;
    Out->GlyphLookupSubtableMatrixOffsetFromStartOfFile = (kbts_u32)WordsAt;
    Out->MatrixBlocksOffsetFromStartOfFile = (kbts_u32)BlocksAt;
  }
  return (int)At;
}
