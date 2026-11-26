# Tiny Synth: the finished project of docs/TUTORIAL_LAZARUS_SYNTH.md.
# The Pascal sources and the form are exactly the tutorial's. Only this file
# differs: its own target name, product name, codes and bundle id, so that it
# can be built beside the copy a reader makes in plugins/TinySynth (CMake
# targets and plug-in ids must be unique).
pascaljuce_add_plugin(TinySynthExample
    PRODUCT_NAME      "Tiny Synth Example"
    COMPANY_NAME      "PascalJUCE"
    COMPANY_WEBSITE   "https://example.com"
    MANUFACTURER_CODE Pjuc            # 4 chars, at least one capital: the same for all your plug-ins
    PLUGIN_CODE       Tny0            # 4 chars, unique for each plug-in (the tutorial uses Tny1)
    BUNDLE_ID         com.example.tinysynthexample
    KIND              instrument
    VERSION           0.1.0
    PASCAL_SOURCE     TinySynth.lpr
    PARAMETER_LIST    TinySynth.params
)
