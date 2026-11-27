object Mz303EditorForm: TMz303EditorForm
  Left = 0
  Top = 0
  Caption = 'Mz303_Pascal editor (design only)'
  ClientHeight = 430
  ClientWidth = 1040
  Color = 12830662
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object Title: TJuceLabel
    Left = 18
    Top = 10
    Width = 120
    Height = 36
    Caption = 'Mz303'
    FontSize = 28
    Bold = True
    Alignment = jaLeft
  end
  object Subtitle: TJuceLabel
    Left = 116
    Top = 10
    Width = 300
    Height = 38
    Caption = 'BASS LINE'
    FontSize = 12
    Bold = True
    Alignment = jaLeft
    Color = -10855329
  end
  object ProjectLink: TJuceLink
    Left = 370
    Top = 14
    Width = 420
    Height = 26
    Hint = 'The project''s page: the latest version and what''s new in it, the source, and where to report a problem. Opens in your browser.'
    Caption = 'Mz303_Pascal 0.3.0  -  github.com/simozzer/Mz303'
    FontSize = 13
    Bold = True
    Alignment = jaRight
    Color = -16035928
    Url = 'https://github.com/simozzer/Mz303'
  end
  object PatchBox: TJuceComboBox
    Left = 806
    Top = 14
    Width = 220
    Height = 26
    Hint = 'Factory patches. Your own edits are saved with the project.'
    ParameterId = 'patch'
    Color = -4736844
    BorderColor = -7434100
    TextColor = -15461356
    FontSize = 13
  end
  object KnobSection: TJucePanel
    Left = 14
    Top = 56
    Width = 1012
    Height = 150
    Color = -4736844
    BorderColor = -7434100
    CornerRadius = 4
    object Tune: TJuceKnob
      Left = 12
      Top = 8
      Width = 96
      Height = 134
      Hint = 'TUNING'#10'Fine tuning, a semitone either way. Double-click for A = 440 Hz.'#10'MIDI CC 14. Right-click to learn another.'
      Caption = 'TUNING'
      ParameterId = 'tune'
      DefaultValue = 0.5
      ShowValue = False
      Bipolar = True
      Sensitivity = 220
      BodyColor = -14935010
      PointerColor = -1447450
      TextColor = -15461356
      ValueBubble = jvbDragAndHover
    end
    object Cutoff: TJuceKnob
      Left = 124
      Top = 8
      Width = 96
      Height = 134
      Hint = 'CUT OFF FREQ'#10'Filter cutoff. Lower is darker; the envelope and accents sweep up from here.'#10'MIDI CC 74. Right-click to learn another.'
      Caption = 'CUT OFF FREQ'
      ParameterId = 'cutoff'
      DefaultValue = 0.400000005960464
      ShowValue = False
      Sensitivity = 220
      BodyColor = -14935010
      PointerColor = -1447450
      TextColor = -15461356
      ValueBubble = jvbDragAndHover
    end
    object Res: TJuceKnob
      Left = 236
      Top = 8
      Width = 96
      Height = 134
      Hint = 'RESONANCE'#10'Filter resonance: the squelch. Also makes accents swell rather than spike, and climb on a run of them.'#10'MIDI CC 71. Right-click to learn another.'
      Caption = 'RESONANCE'
      ParameterId = 'res'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 220
      BodyColor = -14935010
      PointerColor = -1447450
      TextColor = -15461356
      ValueBubble = jvbDragAndHover
    end
    object EnvMod: TJuceKnob
      Left = 348
      Top = 8
      Width = 96
      Height = 134
      Hint = 'ENV MOD'#10'How far the envelope sweeps the filter on each note. Turning it up also lowers where the filter rests.'#10'MIDI CC 15. Right-click to learn another.'
      Caption = 'ENV MOD'
      ParameterId = 'envMod'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 220
      BodyColor = -14935010
      PointerColor = -1447450
      TextColor = -15461356
      ValueBubble = jvbDragAndHover
    end
    object Decay: TJuceKnob
      Left = 460
      Top = 8
      Width = 96
      Height = 134
      Hint = 'DECAY'#10'How long the filter''s envelope takes to close, 0.2 to 2.5 s. Accented notes always close at the shortest.'#10'MIDI CC 75. Right-click to learn another.'
      Caption = 'DECAY'
      ParameterId = 'decay'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 220
      BodyColor = -14935010
      PointerColor = -1447450
      TextColor = -15461356
      ValueBubble = jvbDragAndHover
    end
    object Accent: TJuceKnob
      Left = 572
      Top = 8
      Width = 96
      Height = 134
      Hint = 'ACCENT'#10'How much an accent lifts the filter and the volume. A note is accented when its velocity is 100 or more.'#10'MIDI CC 16. Right-click to learn another.'
      Caption = 'ACCENT'
      ParameterId = 'accent'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 220
      BodyColor = -14935010
      PointerColor = -1447450
      TextColor = -15461356
      ValueBubble = jvbDragAndHover
    end
    object Wave: TJuceSwitch
      Left = 684
      Top = 8
      Width = 84
      Height = 134
      Hint = 'WAVEFORM'#10'SAW, or SQUARE - the saw through a waveshaper, so its halves still lean.'#10'MIDI CC 70. Right-click to learn another.'
      Caption = 'WAVEFORM'
      ParameterId = 'wave'
      Orientation = joVertical
      Labels = 'SAW|SQUARE'
      TextColor = -15461356
      SlotColor = -15066598
      LeverColor = -15592942
      Style = jswSlide
    end
    object Volume: TJuceKnob
      Left = 784
      Top = 8
      Width = 96
      Height = 134
      Hint = 'VOLUME'#10'Output level.'#10'MIDI CC 7. Right-click to learn another.'
      Caption = 'VOLUME'
      ParameterId = 'volume'
      DefaultValue = 0.699999988079071
      ShowValue = False
      Sensitivity = 220
      BodyColor = -14935010
      PointerColor = -1447450
      TextColor = -15461356
      ValueBubble = jvbDragAndHover
    end
    object AccentLight: TJuceLed
      Left = 899
      Top = 56
      Width = 14
      Height = 14
      Hint = 'Lit while the note playing is accented (velocity 100 or more).'
      MeterIndex = 0
      Color = -2608609
    end
    object AccentLabel: TJuceLabel
      Left = 920
      Top = 48
      Width = 80
      Height = 30
      Caption = 'ACCENT'
      FontSize = 12
      Bold = True
      Alignment = jaLeft
    end
    object SlideLight: TJuceLed
      Left = 899
      Top = 96
      Width = 14
      Height = 14
      Hint = 'Lit while the note playing was slid into (played over the note before).'
      MeterIndex = 1
      Color = -2608609
    end
    object SlideLabel: TJuceLabel
      Left = 920
      Top = 88
      Width = 80
      Height = 30
      Caption = 'SLIDE'
      FontSize = 12
      Bold = True
      Alignment = jaLeft
    end
  end
  object KeyboardBox: TJucePanel
    Left = 14
    Top = 218
    Width = 1012
    Height = 198
    Color = -14013651
    BorderWidth = 0
    CornerRadius = 4
    object AccentKeys: TJuceButton
      Left = 16
      Top = 77
      Width = 64
      Height = 44
      Hint = 'Latch to play the on-screen keys accented. From MIDI, velocity 100 or more is an accent, and a note played before the last is let go slides.'
      Caption = 'ACCENT'
      LedColor = -2608609
      FaceColor = -15329770
      TextColor = -1447450
      LedPosition = jlpTop
      BorderColor = -7434100
      CornerRadius = 3
    end
    object Keyboard: TJuceKeyboard
      Left = 92
      Top = 12
      Width = 908
      Height = 174
      FirstNote = 24
      LastNote = 60
      OctaveForMiddleC = 4
      KeyDownColor = -1713884641
      HoverColor = 1087910431
    end
  end
  object Theme: TJuceThemeResource
    Left = 12
    Top = 12
    Background = -3749949
    Panel = -4736844
    PanelBorder = -7434100
    Text = -15461356
    TextDim = -10855329
    Accent = -2608609
    Track = -15066598
    KnobBody = -14935010
    KnobPointer = -1447450
    ButtonFace = -15329770
    LedOn = -1028038
    LedOff = -11920360
    FontSize = 12
    TooltipBackground = -15658476
    TooltipText = -1447450
    TooltipBorder = -2608609
    MenuBackground = -14013651
    MenuText = -1447450
    MenuHighlight = -2608609
    MenuHighlightText = -1
    BubbleBackground = -14013651
    BubbleText = -1447450
    BubbleBorder = -7434100
    BubbleFontSize = 13
    Link = -16035928
  end
end
