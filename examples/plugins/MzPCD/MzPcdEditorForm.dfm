object MzPcdEditorForm: TMzPcdEditorForm
  Left = 0
  Top = 0
  Caption = 'MzPCD_Pascal editor (design only)'
  ClientHeight = 186
  ClientWidth = 966
  Color = 2828070
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object Face: TJucePanel
    Left = 10
    Top = 10
    Width = 946
    Height = 166
    Color = -12434618
    GradientColor = -12960962
    BorderColor = -1728053248
    BorderWidth = 1
    CornerRadius = 3
  end
  object Title: TJuceLabel
    Left = 24
    Top = 18
    Width = 300
    Height = 28
    Caption = 'MzPCD'
    FontSize = 22
    Bold = True
    Alignment = jaLeft
    Color = -1447450
  end
  object Subtitle: TJuceLabel
    Left = 106
    Top = 18
    Width = 400
    Height = 28
    Caption = 'PATTERN CONTROLLED DISTORTION'
    FontSize = 10.5
    Bold = True
    Alignment = jaLeft
    Color = -1712723482
  end
  object ProjectLink: TJuceLink
    Left = 582
    Top = 18
    Width = 360
    Height = 28
    Hint = 'The project''s page: the latest version and what''s new in it, the source, and where to' +
      ' report a problem. Opens in your browser.'
    Caption = 'MzPCD_Pascal 0.4.0  -  github.com/simozzer/MzPCD'
    FontSize = 11.5
    Bold = True
    Alignment = jaRight
    Color = -9785089
    Url = 'https://github.com/simozzer/MzPCD'
  end
  object PcdUnit: TJucePanel
    Left = 20
    Top = 48
    Width = 788
    Height = 120
    Color = -12824733
    GradientColor = -13285800
    BorderColor = -1728053248
    BorderWidth = 1
    CornerRadius = 3
  end
  object OutUnit: TJucePanel
    Left = 816
    Top = 48
    Width = 130
    Height = 120
    Color = -12824733
    GradientColor = -13285800
    BorderColor = -1728053248
    BorderWidth = 1
    CornerRadius = 3
  end
  object PcdTag: TJucePanel
    Left = 28
    Top = 54
    Width = 60
    Height = 15
    Color = -14536642
    BorderWidth = 0
    CornerRadius = 2
  end
  object PcdTagText: TJuceLabel
    Left = 28
    Top = 54
    Width = 60
    Height = 15
    Caption = 'PCD'
    FontSize = 10.5
    Bold = True
    Color = -1447450
  end
  object OutTag: TJucePanel
    Left = 824
    Top = 54
    Width = 60
    Height = 15
    Color = -14536642
    BorderWidth = 0
    CornerRadius = 2
  end
  object OutTagText: TJuceLabel
    Left = 824
    Top = 54
    Width = 60
    Height = 15
    Caption = 'OUTPUT'
    FontSize = 10.5
    Bold = True
    Color = -1447450
  end
  object LevelsGroup: TJuceLabel
    Left = 318
    Top = 72
    Width = 222
    Height = 12
    Caption = 'LEVELS'
    FontSize = 9
    Bold = True
    Color = -857085466
  end
  object PushesGroup: TJuceLabel
    Left = 558
    Top = 72
    Width = 222
    Height = 12
    Caption = 'PATTERN PUSHES'
    FontSize = 9
    Bold = True
    Color = -857085466
  end
  object PatternLegend: TJuceLabel
    Left = 28
    Top = 81
    Width = 60
    Height = 12
    Caption = 'PATTERN'
    FontSize = 9
    Bold = True
    Alignment = jaLeft
    Color = -1075189274
  end
  object PatternNumber: TJuceDisplay
    Left = 28
    Top = 94
    Width = 44
    Height = 32
    Caption = '1'
    Color = -15333882
    TextColor = -50398
    BorderColor = -16777216
    BorderWidth = 1
    CornerRadius = 2
    FontName = 'Lucida Console'
    FontSize = 25
    Bold = True
    Alignment = jaRight
  end
  object PatternDisplay: TJuceDisplay
    Left = 80
    Top = 80
    Width = 164
    Height = 78
    Color = -15333882
    TextColor = -50398
    BorderColor = -16777216
    BorderWidth = 1
    CornerRadius = 2
  end
  object Rate: TJuceButton
    Left = 252
    Top = 82
    Width = 54
    Height = 46
    ParameterId = 'rate'
    Caption = 'RATE'
    ShowLed = False
    FaceColor = -15000803
    TextColor = -1447450
    CornerRadius = 3
  end
  object Drive: TJuceKnob
    Left = 318
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'drive'
    Caption = 'DRIVE'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Shape: TJuceKnob
    Left = 374
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'shape'
    Caption = 'SHAPE'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Tone: TJuceKnob
    Left = 430
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'tone'
    Caption = 'TONE'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Feedback: TJuceKnob
    Left = 486
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'feedback'
    Caption = 'FDBK'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object DriveAmount: TJuceKnob
    Left = 558
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'driveAmount'
    Caption = 'DRIVE'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object ToneAmount: TJuceKnob
    Left = 614
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'toneAmount'
    Caption = 'TONE'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object FeedbackAmount: TJuceKnob
    Left = 670
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'feedbackAmount'
    Caption = 'FDBK'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Decay: TJuceKnob
    Left = 726
    Top = 86
    Width = 54
    Height = 76
    ParameterId = 'decay'
    Caption = 'DEC'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Mix: TJuceKnob
    Left = 824
    Top = 86
    Width = 56
    Height = 76
    ParameterId = 'mix'
    Caption = 'MIX'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Level: TJuceKnob
    Left = 880
    Top = 86
    Width = 56
    Height = 76
    ParameterId = 'level'
    Caption = 'LEVEL'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Theme: TJuceThemeResource
    Left = 12
    Top = 12
    Background = -14276821
    Text = -1447450
    TextDim = -1712723482
    Accent = -2608609
    TooltipBackground = -15658476
    TooltipText = -1447450
    TooltipBorder = -2608609
    BubbleBackground = -14276821
    BubbleText = -1447450
    BubbleBorder = -7499885
    BubbleFontSize = 15
    Link = -9785089
  end
end
