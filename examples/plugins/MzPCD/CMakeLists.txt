# MzPCD_Pascal - the MzPCD pattern-controlled distortion (github.com/simozzer/MzPCD), ported
# to Object Pascal on PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++
# MzPCD in a DAW rather than replacing it.
#
# An effect: stereo in and out, or mono in and out, as the C++ MzPCD. It follows the host's
# transport (no MIDI), and reports the oversampler's delay (31 samples) as its latency.
#
# PCD/ holds the engine (ReBirth's distortion, the oversampler, the tone and the feedback
# loop). The patterns, the step clock, the envelope and the panel's controls are MzPCF's,
# shared rather than copied - as the C++ MzPCD compiles MzPCF's Source/PCF.
pascaljuce_add_plugin(MzPCD
    PRODUCT_NAME      "MzPCD_Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ MzPCD's manufacturer code
    PLUGIN_CODE       Pcdp            # unique: the C++ one is Pcd1
    BUNDLE_ID         com.simozzer.mzpcdpascal
    KIND              effect
    VERSION           0.4.0
    PASCAL_SOURCE     MzPCD.dpr
    PASCAL_UNIT_PATHS PCD ../MzPCF/PCF
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ MzPCD
    PARAMETER_LIST    MzPCD.params    # for the form designer (MzPcdEditorForm.lfm)
)
