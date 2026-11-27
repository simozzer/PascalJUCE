# Mz950_Pascal - the VirtualS950 Akai S950 sampler (Mz950), ported to Object Pascal on
# PascalJUCE. Its own PLUGIN_CODE and BUNDLE_ID, so it sits beside the C++ VirtualS950 in a
# DAW rather than replacing it (its saved state is its own format, too).
#
# One stereo (or mono) output, as the C++: a keygroup can be sent to LEFT or RIGHT, so the
# engine renders two channels; a mono host gets the left.
pascaljuce_add_plugin(Mz950
    PRODUCT_NAME      "Mz950_Pascal"
    COMPANY_NAME      "simozzer"
    COMPANY_WEBSITE   "https://github.com/simozzer"
    MANUFACTURER_CODE Smoz            # the C++ plug-ins' manufacturer code
    PLUGIN_CODE       Mzp5            # unique: the C++ one is Ak95
    BUNDLE_ID         com.simozzer.mz950pascal
    KIND              instrument
    VERSION           0.12.2          # the C++ VirtualS950's
    PASCAL_SOURCE     Mz950.dpr
    LICENSE_FILE      LICENSE         # GNU AGPL v3, as the C++ VirtualS950
)
