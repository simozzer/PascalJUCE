# MzPCG_Pascal - the MzPCG pattern-controlled gain (github.com/simozzer/MzPCG), ported to
# Object Pascal on PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++
# MzPCG in a DAW rather than replacing it.
#
# An effect: stereo in and out, or mono in and out, as the C++ MzPCG. It follows the host's
# transport (no MIDI).
#
# As the C++ MzPCG compiles MzPCF's Source/PCF, this plays MzPCF_Pascal's patterns and step
# clock, and draws its panel with MzPCF_Pascal's controls: ../MzPCF/PCF, shared, not copied.
# PCG/ holds its own engine and the gain's picture.
pascaljuce_add_plugin(MzPCG
    PRODUCT_NAME      "MzPCG_Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ MzPCG's manufacturer code
    PLUGIN_CODE       Pcgp            # unique: the C++ one is Pcg1
    BUNDLE_ID         com.simozzer.mzpcgpascal
    KIND              effect
    VERSION           0.3.0
    PASCAL_SOURCE     MzPCG.dpr
    PASCAL_UNIT_PATHS ../MzPCF/PCF PCG
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ MzPCG
    PARAMETER_LIST    MzPCG.params    # for the form designer (MzPcgEditorForm.lfm)
)
