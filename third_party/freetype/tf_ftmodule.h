/* The FreeType modules TIDALfast's Windows build has: TrueType and CFF
   outlines, the SFNT tables (cmap, CBDT colour bitmaps, variations) and
   the anti-aliasing rasterizer. build.py points FT_CONFIG_MODULES_H here. */
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
