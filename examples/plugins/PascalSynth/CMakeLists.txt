pascaljuce_add_plugin(PascalSynth
    PRODUCT_NAME      "Pascal Synth"
    COMPANY_NAME      "PascalJUCE"
    COMPANY_WEBSITE   "https://example.com"
    MANUFACTURER_CODE Pjuc            # 4 chars, at least one upper-case; yours, consistently
    PLUGIN_CODE       Psy1            # 4 chars, unique per plugin
    BUNDLE_ID         com.example.pascalsynth
    KIND              instrument      # instrument | effect | midi_effect
    VERSION           0.1.0
    PASCAL_SOURCE     PascalSynth.dpr # compiled with Free Pascal
    # PASCAL_LIBRARY  path/to/PascalSynth.dll   # ...or a DLL you built in Delphi
)
