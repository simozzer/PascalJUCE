object Mz909EditorForm: TMz909EditorForm
  Left = 0
  Top = 0
  Caption = 'Mz909_Pascal editor (design only)'
  ClientHeight = 540
  ClientWidth = 1198
  Color = 1907483
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object BandLeft: TJucePanel
    Left = 0
    Top = 0
    Width = 599
    Height = 4
    Color = -2606805
    GradientColor = -1086433
    GradientVertical = False
    BorderWidth = 0
    CornerRadius = 0
  end
  object BandRight: TJucePanel
    Left = 599
    Top = 0
    Width = 599
    Height = 4
    Color = -1086433
    GradientColor = -875974
    GradientVertical = False
    BorderWidth = 0
    CornerRadius = 0
  end
  object Title: TJuceLabel
    Left = 16
    Top = 10
    Width = 120
    Height = 38
    Caption = 'Mz909'
    FontSize = 28
    Bold = True
    Alignment = jaLeft
  end
  object Subtitle: TJuceLabel
    Left = 114
    Top = 10
    Width = 300
    Height = 40
    Caption = 'RHYTHM COMPOSER'
    FontSize = 12
    Bold = True
    Alignment = jaLeft
    Color = -1086433
  end
  object ProjectLink: TJuceLink
    Left = 528
    Top = 14
    Width = 420
    Height = 26
    Hint = 'The project''s page: the latest version and what''s new in it, the source, and where to' +
      ' report a problem. Opens in your browser.'
    Caption = 'Mz909_Pascal 0.3.0  -  github.com/simozzer/Mz909'
    FontSize = 13
    Bold = True
    Alignment = jaRight
    Color = -9785089
    Url = 'https://github.com/simozzer/Mz909'
  end
  object PatchBox: TJuceComboBox
    Left = 964
    Top = 14
    Width = 220
    Height = 26
    Hint = 'Factory kits. Your own edits are saved with the project.'
    ParameterId = 'patch'
    Color = -14342872
    BorderColor = -12961216
    TextColor = -1513760
    FontSize = 13
  end
  object AccentColumn: TJucePanel
    Left = 14
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object AccentTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'ACCENT'
      FontSize = 11
      Bold = True
    end
    object AccentLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -2606805
      BorderWidth = 0
      CornerRadius = 0
    end
    object Accent: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'ACCENT'#10'How much harder an accented hit strikes: velocity above 100 is an accent. It does not just' +
        ' turn the sound up - an accented kick sweeps from higher, and the drums push their output' +
        ' stages harder.'#10'MIDI CC 14. Right-click to learn another.'
      ParameterId = 'accent'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656918229
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2606805
      ValueBubble = jvbDragAndHover
    end
    object AccentLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object AccentButton: TJuceButton
      Left = 10
      Top = 380
      Width = 72
      Height = 40
      Hint = 'ACCENT'#10'Lit, the pads play accented hits - as velocity above 100 does from MIDI. Shift-click a pad' +
        ' for one accented hit.'
      Caption = 'ACCENT'
      LedColor = -1871513
      FaceColor = -15329770
      TextColor = -1513760
      LedPosition = jlpTop
      Flat = True
      BorderColor = -12961216
      CornerRadius = 3
    end
  end
  object BassDrumColumn: TJucePanel
    Left = 112
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object BassDrumTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'BASS DRUM'
      FontSize = 11
      Bold = True
    end
    object BassDrumLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -1086433
      BorderWidth = 0
      CornerRadius = 0
    end
    object BdLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'BASS DRUM LEVEL'#10'Level of the bass drum.'#10'MIDI CC 15. Right-click to learn another.'
      ParameterId = 'bdLevel'
      DefaultValue = 0.800000011920929
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object BdLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object BdTune: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'BASS DRUM TUNE'#10'How far and how long the kick''s pitch falls: a short, tight drop at 0, a long, deep sweep' +
        ' at 10.'#10'MIDI CC 16. Right-click to learn another.'
      ParameterId = 'bdTune'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object BdTuneLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'TUNE'
      FontSize = 10.5
      Bold = True
    end
    object BdAttack: TJuceKnob
      Left = 13
      Top = 196
      Width = 66
      Height = 58
      Hint = 'BASS DRUM ATTACK'#10'The beater: how much click and noise is on the front of the kick.'#10'MIDI CC 17. Right-click to learn another.'
      ParameterId = 'bdAttack'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object BdAttackLegend: TJuceLabel
      Left = 4
      Top = 254
      Width = 84
      Height = 18
      Caption = 'ATTACK'
      FontSize = 10.5
      Bold = True
    end
    object BdDecay: TJuceKnob
      Left = 13
      Top = 272
      Width = 66
      Height = 58
      Hint = 'BASS DRUM DECAY'#10'How long the bass drum rings: a short thump at 0, a long boom at 10.'#10'MIDI CC 18. Right-click to learn another.'
      ParameterId = 'bdDecay'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object BdDecayLegend: TJuceLabel
      Left = 4
      Top = 330
      Width = 84
      Height = 18
      Caption = 'DECAY'
      FontSize = 10.5
      Bold = True
    end
    object LedBD: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'BASS DRUM'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadBD: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'BASS DRUM'#10'MIDI note 36 (C1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -3187430
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeBD: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'BD'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteBD: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '36'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object SnareDrumColumn: TJucePanel
    Left = 210
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object SnareDrumTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'SNARE DRUM'
      FontSize = 11
      Bold = True
    end
    object SnareDrumLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -1086433
      BorderWidth = 0
      CornerRadius = 0
    end
    object SdLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'SNARE DRUM LEVEL'#10'Level of the snare drum.'#10'MIDI CC 19. Right-click to learn another.'
      ParameterId = 'sdLevel'
      DefaultValue = 0.699999988079071
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object SdLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object SdTune: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'SNARE DRUM TUNE'#10'Pitch of the drum head, a little over a quarter-octave either way.'#10'MIDI CC 20. Right-click to learn another.'
      ParameterId = 'sdTune'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object SdTuneLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'TUNE'
      FontSize = 10.5
      Bold = True
    end
    object SdTone: TJuceKnob
      Left = 13
      Top = 196
      Width = 66
      Height = 58
      Hint = 'SNARE DRUM TONE'#10'How bright the snares are: dark at 0, crisp at 10.'#10'MIDI CC 21. Right-click to learn another.'
      ParameterId = 'sdTone'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object SdToneLegend: TJuceLabel
      Left = 4
      Top = 254
      Width = 84
      Height = 18
      Caption = 'TONE'
      FontSize = 10.5
      Bold = True
    end
    object SdSnappy: TJuceKnob
      Left = 13
      Top = 272
      Width = 66
      Height = 58
      Hint = 'SNARE DRUM SNAPPY'#10'How much of the snares - the noise - goes in.'#10'MIDI CC 22. Right-click to learn another.'
      ParameterId = 'sdSnappy'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object SdSnappyLegend: TJuceLabel
      Left = 4
      Top = 330
      Width = 84
      Height = 18
      Caption = 'SNAPPY'
      FontSize = 10.5
      Bold = True
    end
    object LedSD: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'SNARE DRUM'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadSD: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'SNARE DRUM'#10'MIDI note 38 (D1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -3187430
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeSD: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'SD'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteSD: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '38'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object LowTomColumn: TJucePanel
    Left = 308
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object LowTomTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'LOW TOM'
      FontSize = 11
      Bold = True
    end
    object LowTomLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -1086433
      BorderWidth = 0
      CornerRadius = 0
    end
    object LtLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'LOW TOM LEVEL'#10'Level of the low tom.'#10'MIDI CC 23. Right-click to learn another.'
      ParameterId = 'ltLevel'
      DefaultValue = 0.699999988079071
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object LtLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object LtTune: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'LOW TOM TUNE'#10'Pitch of the low tom, half an octave either way.'#10'MIDI CC 24. Right-click to learn another.'
      ParameterId = 'ltTune'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object LtTuneLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'TUNE'
      FontSize = 10.5
      Bold = True
    end
    object LtDecay: TJuceKnob
      Left = 13
      Top = 196
      Width = 66
      Height = 58
      Hint = 'LOW TOM DECAY'#10'How long the low tom rings.'#10'MIDI CC 25. Right-click to learn another.'
      ParameterId = 'ltDecay'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object LtDecayLegend: TJuceLabel
      Left = 4
      Top = 254
      Width = 84
      Height = 18
      Caption = 'DECAY'
      FontSize = 10.5
      Bold = True
    end
    object LedLT: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'LOW TOM'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadLT: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'LOW TOM'#10'MIDI note 43 (G1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -3187430
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeLT: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'LT'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteLT: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '43'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object MidTomColumn: TJucePanel
    Left = 406
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object MidTomTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'MID TOM'
      FontSize = 11
      Bold = True
    end
    object MidTomLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -1086433
      BorderWidth = 0
      CornerRadius = 0
    end
    object MtLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'MID TOM LEVEL'#10'Level of the mid tom.'#10'MIDI CC 26. Right-click to learn another.'
      ParameterId = 'mtLevel'
      DefaultValue = 0.699999988079071
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object MtLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object MtTune: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'MID TOM TUNE'#10'Pitch of the mid tom, half an octave either way.'#10'MIDI CC 27. Right-click to learn another.'
      ParameterId = 'mtTune'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object MtTuneLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'TUNE'
      FontSize = 10.5
      Bold = True
    end
    object MtDecay: TJuceKnob
      Left = 13
      Top = 196
      Width = 66
      Height = 58
      Hint = 'MID TOM DECAY'#10'How long the mid tom rings.'#10'MIDI CC 28. Right-click to learn another.'
      ParameterId = 'mtDecay'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object MtDecayLegend: TJuceLabel
      Left = 4
      Top = 254
      Width = 84
      Height = 18
      Caption = 'DECAY'
      FontSize = 10.5
      Bold = True
    end
    object LedMT: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'MID TOM'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadMT: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'MID TOM'#10'MIDI note 47 (B1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -3187430
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeMT: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'MT'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteMT: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '47'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object HiTomColumn: TJucePanel
    Left = 504
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object HiTomTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'HI TOM'
      FontSize = 11
      Bold = True
    end
    object HiTomLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -1086433
      BorderWidth = 0
      CornerRadius = 0
    end
    object HtLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'HI TOM LEVEL'#10'Level of the hi tom.'#10'MIDI CC 29. Right-click to learn another.'
      ParameterId = 'htLevel'
      DefaultValue = 0.699999988079071
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object HtLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object HtTune: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'HI TOM TUNE'#10'Pitch of the hi tom, half an octave either way.'#10'MIDI CC 30. Right-click to learn another.'
      ParameterId = 'htTune'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object HtTuneLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'TUNE'
      FontSize = 10.5
      Bold = True
    end
    object HtDecay: TJuceKnob
      Left = 13
      Top = 196
      Width = 66
      Height = 58
      Hint = 'HI TOM DECAY'#10'How long the hi tom rings.'#10'MIDI CC 31. Right-click to learn another.'
      ParameterId = 'htDecay'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655397857
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -1086433
      ValueBubble = jvbDragAndHover
    end
    object HtDecayLegend: TJuceLabel
      Left = 4
      Top = 254
      Width = 84
      Height = 18
      Caption = 'DECAY'
      FontSize = 10.5
      Bold = True
    end
    object LedHT: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'HI TOM'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadHT: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'HI TOM'#10'MIDI note 50 (D2).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -3187430
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeHT: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'HT'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteHT: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '50'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object RimShotColumn: TJucePanel
    Left = 602
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object RimShotTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'RIM SHOT'
      FontSize = 11
      Bold = True
    end
    object RimShotLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -875974
      BorderWidth = 0
      CornerRadius = 0
    end
    object RsLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'RIM SHOT LEVEL'#10'Level of the rim shot.'#10'MIDI CC 102. Right-click to learn another.'
      ParameterId = 'rsLevel'
      DefaultValue = 0.600000023841858
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655187398
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -875974
      ValueBubble = jvbDragAndHover
    end
    object RsLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object LedRS: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'RIM SHOT'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadRS: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'RIM SHOT'#10'MIDI note 37 (C#1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -2978766
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeRS: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'RS'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteRS: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '37'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object HandClapColumn: TJucePanel
    Left = 700
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object HandClapTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'HAND CLAP'
      FontSize = 11
      Bold = True
    end
    object HandClapLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -875974
      BorderWidth = 0
      CornerRadius = 0
    end
    object CpLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'HAND CLAP LEVEL'#10'Level of the hand clap.'#10'MIDI CC 103. Right-click to learn another.'
      ParameterId = 'cpLevel'
      DefaultValue = 0.699999988079071
      ShowValue = False
      Sensitivity = 180
      ArcColor = -655187398
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -875974
      ValueBubble = jvbDragAndHover
    end
    object CpLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object LedCP: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'HAND CLAP'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadCP: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'HAND CLAP'#10'MIDI note 39 (D#1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -2978766
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeCP: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'CP'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteCP: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '39'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object HiHatColumn: TJucePanel
    Left = 798
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object HiHatTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'HI HAT'
      FontSize = 11
      Bold = True
    end
    object HiHatLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -2500396
      BorderWidth = 0
      CornerRadius = 0
    end
    object HhLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'HIHAT LEVEL'#10'Level of both hihats, which share one DAC and one VCA.'#10'MIDI CC 104. Right-click to learn another.'
      ParameterId = 'hhLevel'
      DefaultValue = 0.600000023841858
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656811820
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2500396
      ValueBubble = jvbDragAndHover
    end
    object HhLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object ChDecay: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'CLOSED HIHAT DECAY'#10'How long the closed hihat rings before its VCA shuts. 5 is the measured hat.'#10'MIDI CC 105. Right-click to learn another.'
      ParameterId = 'chDecay'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656811820
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2500396
      ValueBubble = jvbDragAndHover
    end
    object ChDecayLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'CH DECAY'
      FontSize = 10.5
      Bold = True
    end
    object OhDecay: TJuceKnob
      Left = 13
      Top = 196
      Width = 66
      Height = 58
      Hint = 'OPEN HIHAT DECAY'#10'How long the open hihat rings before its VCA shuts; 10 is the measured hat. A closed hihat' +
        ' cuts it off.'#10'MIDI CC 106. Right-click to learn another.'
      ParameterId = 'ohDecay'
      DefaultValue = 1
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656811820
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2500396
      ValueBubble = jvbDragAndHover
    end
    object OhDecayLegend: TJuceLabel
      Left = 4
      Top = 254
      Width = 84
      Height = 18
      Caption = 'OH DECAY'
      FontSize = 10.5
      Bold = True
    end
    object LedCH: TJuceLed
      Left = 20
      Top = 358
      Width = 9
      Height = 9
      Hint = 'CLOSED HIHAT'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadCH: TJuceButton
      Left = 5
      Top = 372
      Width = 38
      Height = 56
      Hint = 'CLOSED HIHAT'#10'MIDI note 42 (F#1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -4408392
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeCH: TJuceLabel
      Left = 6
      Top = 381
      Width = 36
      Height = 18
      Caption = 'CH'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteCH: TJuceLabel
      Left = 6
      Top = 408
      Width = 36
      Height = 14
      Caption = '42'
      FontSize = 9.5
      Color = -15000803
    end
    object LedOH: TJuceLed
      Left = 64
      Top = 358
      Width = 9
      Height = 9
      Hint = 'OPEN HIHAT'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadOH: TJuceButton
      Left = 49
      Top = 372
      Width = 38
      Height = 56
      Hint = 'OPEN HIHAT'#10'MIDI note 46 (A#1).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -4408392
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeOH: TJuceLabel
      Left = 50
      Top = 381
      Width = 36
      Height = 18
      Caption = 'OH'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteOH: TJuceLabel
      Left = 50
      Top = 408
      Width = 36
      Height = 14
      Caption = '46'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object CrashColumn: TJucePanel
    Left = 896
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object CrashTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'CRASH'
      FontSize = 11
      Bold = True
    end
    object CrashLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -2500396
      BorderWidth = 0
      CornerRadius = 0
    end
    object CrLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'CRASH LEVEL'#10'Level of the crash cymbal.'#10'MIDI CC 107. Right-click to learn another.'
      ParameterId = 'crLevel'
      DefaultValue = 0.600000023841858
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656811820
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2500396
      ValueBubble = jvbDragAndHover
    end
    object CrLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object CrTune: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'CRASH TUNE'#10'The speed the crash''s sample plays at: lower and longer at 0, higher and shorter at 10.'#10'MIDI CC 108. Right-click to learn another.'
      ParameterId = 'crTune'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656811820
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2500396
      ValueBubble = jvbDragAndHover
    end
    object CrTuneLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'TUNE'
      FontSize = 10.5
      Bold = True
    end
    object LedCC: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'CRASH CYMBAL'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadCC: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'CRASH CYMBAL'#10'MIDI note 49 (C#2).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -4408392
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeCC: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'CC'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteCC: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '49'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object RideColumn: TJucePanel
    Left = 994
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object RideTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'RIDE'
      FontSize = 11
      Bold = True
    end
    object RideLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -2500396
      BorderWidth = 0
      CornerRadius = 0
    end
    object RdLevel: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'RIDE LEVEL'#10'Level of the ride cymbal.'#10'MIDI CC 109. Right-click to learn another.'
      ParameterId = 'rdLevel'
      DefaultValue = 0.600000023841858
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656811820
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2500396
      ValueBubble = jvbDragAndHover
    end
    object RdLevelLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'LEVEL'
      FontSize = 10.5
      Bold = True
    end
    object RdTune: TJuceKnob
      Left = 13
      Top = 120
      Width = 66
      Height = 58
      Hint = 'RIDE TUNE'#10'The speed the ride''s sample plays at: lower and longer at 0, higher and shorter at 10.'#10'MIDI CC 110. Right-click to learn another.'
      ParameterId = 'rdTune'
      DefaultValue = 0.5
      ShowValue = False
      Sensitivity = 180
      ArcColor = -656811820
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -2500396
      ValueBubble = jvbDragAndHover
    end
    object RdTuneLegend: TJuceLabel
      Left = 4
      Top = 178
      Width = 84
      Height = 18
      Caption = 'TUNE'
      FontSize = 10.5
      Bold = True
    end
    object LedRC: TJuceLed
      Left = 42
      Top = 358
      Width = 9
      Height = 9
      Hint = 'RIDE CYMBAL'#10'Lit whenever the sound is struck, from the pad, the host or a controller.'
      Color = -2606805
    end
    object PadRC: TJuceButton
      Left = 27
      Top = 372
      Width = 38
      Height = 56
      Hint = 'RIDE CYMBAL'#10'MIDI note 51 (D#2).'#10'Click to play it; shift-click, or light ACCENT, to play it accented.'
      Mode = jbmMomentary
      ShowLed = False
      FaceColor = -4408392
      TextColor = -15000803
      BorderColor = -16053492
      CornerRadius = 3
    end
    object CodeRC: TJuceLabel
      Left = 28
      Top = 381
      Width = 36
      Height = 18
      Caption = 'RC'
      FontSize = 13
      Bold = True
      Color = -15000803
    end
    object NoteRC: TJuceLabel
      Left = 28
      Top = 408
      Width = 36
      Height = 14
      Caption = '51'
      FontSize = 9.5
      Color = -15000803
    end
  end
  object MasterColumn: TJucePanel
    Left = 1092
    Top = 62
    Width = 92
    Height = 438
    Color = -14342872
    BorderColor = -12961216
    CornerRadius = 4
    object MasterTitle: TJuceLabel
      Left = 4
      Top = 2
      Width = 84
      Height = 34
      Caption = 'MASTER'
      FontSize = 11
      Bold = True
    end
    object MasterLine: TJucePanel
      Left = 8
      Top = 39
      Width = 76
      Height = 2
      Color = -4934995
      BorderWidth = 0
      CornerRadius = 0
    end
    object Volume: TJuceKnob
      Left = 13
      Top = 44
      Width = 66
      Height = 58
      Hint = 'VOLUME'#10'Master output level.'#10'MIDI CC 7. Right-click to learn another.'
      ParameterId = 'volume'
      DefaultValue = 0.699999988079071
      ShowValue = False
      Sensitivity = 180
      ArcColor = -659246419
      TrackColor = -16053492
      BodyColor = -13355974
      PointerColor = -4934995
      ValueBubble = jvbDragAndHover
    end
    object VolumeLegend: TJuceLabel
      Left = 4
      Top = 102
      Width = 84
      Height = 18
      Caption = 'VOLUME'
      FontSize = 10.5
      Bold = True
    end
  end
  object Footer: TJuceLabel
    Left = 14
    Top = 504
    Width = 1170
    Height = 24
    Caption = 'Plays from MIDI on the General MIDI drum map - the number on each pad is its note. Velocity above 100 is an accent. Right-click a knob to MIDI-learn it.'
    FontSize = 11
    Alignment = jaLeft
    Color = -7435128
  end
  object Copyright: TJuceLabel
    Left = 14
    Top = 504
    Width = 1170
    Height = 24
    Caption = 'Created by Simon Moscrop'
    FontSize = 11
    Alignment = jaRight
    Color = -7435128
  end
  object Theme: TJuceThemeResource
    Left = 12
    Top = 12
    Background = -15000803
    Panel = -14342872
    PanelBorder = -12961216
    Text = -1513760
    TextDim = -7435128
    Accent = -2606805
    Track = -16053492
    KnobBody = -13355974
    KnobPointer = -1513760
    ButtonFace = -15329770
    LedOn = -1737871
    LedOff = -12970220
    FontSize = 11
    TooltipBackground = -15658476
    TooltipText = -1513760
    TooltipBorder = -2606805
    MenuBackground = -14342872
    MenuText = -1513760
    MenuHighlight = -2606805
    MenuHighlightText = -1
    BubbleBackground = -14342872
    BubbleText = -1513760
    BubbleBorder = -12961216
    BubbleFontSize = 13
    Link = -9785089
  end
end
