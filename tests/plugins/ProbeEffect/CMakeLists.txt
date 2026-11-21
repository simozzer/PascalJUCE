pascaljuce_add_plugin(ProbeEffect
    PRODUCT_NAME      "Probe Effect"
    COMPANY_NAME      "PascalJUCE Tests"
    MANUFACTURER_CODE Pjuc
    PLUGIN_CODE       Prb1
    BUNDLE_ID         org.pascaljuce.tests.probeeffect
    KIND              effect
    MIDI_INPUT        ON
    MIDI_OUTPUT       ON
    FORMATS           VST3 LV2
    PASCAL_SOURCE     ProbeEffect.dpr
)
