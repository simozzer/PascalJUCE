# Mz909_Pascal - the Mz909 TR-909 emulation (github.com/simozzer/Mz909), ported to Object
# Pascal on PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++ Mz909
# in a DAW rather than replacing it.
#
# One stereo output, as the C++ Mz909: the 909 is rendered mono and copied to both
# channels (no individual outputs).
pascaljuce_add_plugin(Mz909
    PRODUCT_NAME      "Mz909_Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ Mz909's manufacturer code
    PLUGIN_CODE       Mzp9            # unique: the C++ one is Tr09
    BUNDLE_ID         com.simozzer.mz909pascal
    KIND              instrument
    VERSION           0.3.0
    PASCAL_SOURCE     Mz909.dpr
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ Mz909
    PARAMETER_LIST    Mz909.params    # for the form designer (Mz909EditorForm.lfm)
)
