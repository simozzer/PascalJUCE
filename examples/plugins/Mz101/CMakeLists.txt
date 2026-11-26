# Mz101 Pascal - the Mz101 SH-101 emulation (github.com/simozzer/Mz101), ported to Object
# Pascal on PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++ Mz101
# in a DAW rather than replacing it.
pascaljuce_add_plugin(Mz101
    PRODUCT_NAME      "Mz101 Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ Mz101's manufacturer code
    PLUGIN_CODE       Mzp1            # unique: the C++ one is Sh01
    BUNDLE_ID         com.simozzer.mz101pascal
    KIND              instrument
    VERSION           0.3.0
    PASCAL_SOURCE     Mz101.dpr
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ Mz101
    PARAMETER_LIST    Mz101.params    # for the form designer (Mz101EditorForm.lfm)
)
