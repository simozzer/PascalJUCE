# Mz808_Pascal - the Mz808 TR-808 emulation (github.com/simozzer/Mz808), ported to Object
# Pascal on PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++ Mz808
# in a DAW rather than replacing it.
pascaljuce_add_plugin(Mz808
    PRODUCT_NAME      "Mz808_Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ Mz808's manufacturer code
    PLUGIN_CODE       Mzp8            # unique: the C++ one is Tr08
    BUNDLE_ID         com.simozzer.mz808pascal
    KIND              instrument      # one stereo output, as the C++ (mono, copied to both)
    VERSION           0.3.0
    PASCAL_SOURCE     Mz808.dpr
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ Mz808
    PARAMETER_LIST    Mz808.params    # for the form designer (Mz808EditorForm.lfm)
)
