# Mz303_Pascal - the Mz303 TB-303 emulation (github.com/simozzer/Mz303), ported to Object
# Pascal on PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++ Mz303
# in a DAW rather than replacing it.
pascaljuce_add_plugin(Mz303
    PRODUCT_NAME      "Mz303_Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ Mz303's manufacturer code
    PLUGIN_CODE       Mzp3            # unique: the C++ one is Tb03
    BUNDLE_ID         com.simozzer.mz303pascal
    KIND              instrument
    VERSION           0.3.0
    PASCAL_SOURCE     Mz303.dpr
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ Mz303
    PARAMETER_LIST    Mz303.params    # for the form designer (Mz303EditorForm.lfm)
)
