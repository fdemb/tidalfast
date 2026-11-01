# Memory

The shell maps two blocks of memory at start and hands them to the app: a persistent block and a frame block. `State` sits at the start of the persistent block, and the rest is an arena. The frame arena is `context.temp_allocator` and resets every frame. `context.allocator` is the persistent arena only inside `start`. Everywhere else an allocation without an explicit allocator panics in debug builds and goes to the heap with an error in the log in release builds, since the persistent arena never frees.

The persistent arena never zeroes what it hands out. The shell maps the block fresh, so the arena only moves forward through pages nobody has written. Zeroing touched every page of the 23 MB of caches made at start (the shaper's 8 MB, the glyph pool, the box table), most of which are never written, and made them count against the app's memory.
