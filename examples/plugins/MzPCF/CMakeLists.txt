# MzPCF_Pascal - the MzPCF pattern-controlled filter (github.com/simozzer/MzPCF), ported to
# Object Pascal on PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++
# MzPCF in a DAW rather than replacing it.
#
# An effect: stereo in and out, or mono in and out, as the C++ MzPCF. It follows the host's
# transport (no MIDI).
#
# PCF/ holds the engine (patterns, step clock, envelope, filter) and the panel's controls,
# with no dependency on this plug-in: MzPCG and MzPCD use them too, with
#     PASCAL_UNIT_PATHS ../MzPCF/PCF
pascaljuce_add_plugin(MzPCF
    PRODUCT_NAME      "MzPCF_Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ MzPCF's manufacturer code
    PLUGIN_CODE       Pcfp            # unique: the C++ one is Pcf1
    BUNDLE_ID         com.simozzer.mzpcfpascal
    KIND              effect
    VERSION           0.3.0
    PASCAL_SOURCE     MzPCF.dpr
    PASCAL_UNIT_PATHS PCF
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ MzPCF
    PARAMETER_LIST    MzPCF.params    # for the form designer (MzPcfEditorForm.lfm)
)
