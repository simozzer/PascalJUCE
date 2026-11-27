# Scope: an oscilloscope effect. Put it on a track: the audio passes through
# unchanged and the window shows it, one trace (left and right mixed).
pascaljuce_add_plugin(Scope
    PRODUCT_NAME      "Scope"
    COMPANY_NAME      "PascalJUCE"
    COMPANY_WEBSITE   "https://example.com"
    MANUFACTURER_CODE Pjuc            # 4 chars, at least one upper-case; yours, consistently
    PLUGIN_CODE       Scp1            # 4 chars, unique per plugin
    BUNDLE_ID         com.example.scope
    KIND              effect
    VERSION           0.1.0
    PASCAL_SOURCE     Scope.dpr
)
