object MzPcgEditorForm: TMzPcgEditorForm
  Left = 0
  Top = 0
  Caption = 'MzPCG_Pascal editor (design only)'
  ClientHeight = 170
  ClientWidth = 840
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
    Width = 820
    Height = 150
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
    Caption = 'MzPCG'
    FontSize = 22
    Bold = True
    Alignment = jaLeft
    Color = -1447450
  end
  object Subtitle: TJuceLabel
    Left = 106
    Top = 18
    Width = 300
    Height = 28
    Caption = 'PATTERN CONTROLLED GAIN'
    FontSize = 10.5
    Bold = True
    Alignment = jaLeft
    Color = -1712723482
  end
  object ProjectLink: TJuceLink
    Left = 456
    Top = 18
    Width = 360
    Height = 28
    Hint = 'The project''s page: the latest version and what''s new in it, the source, and where to' +
      ' report a problem. Opens in your browser.'
    Caption = 'MzPCG_Pascal 0.3.0  -  github.com/simozzer/MzPCG'
    FontSize = 11.5
    Bold = True
    Alignment = jaRight
    Color = -9785089
    Url = 'https://github.com/simozzer/MzPCG'
  end
  object PcgUnit: TJucePanel
    Left = 20
    Top = 48
    Width = 662
    Height = 104
    Color = -12824733
    GradientColor = -13285800
    BorderColor = -1728053248
    BorderWidth = 1
    CornerRadius = 3
  end
  object OutUnit: TJucePanel
    Left = 690
    Top = 48
    Width = 130
    Height = 104
    Color = -12824733
    GradientColor = -13285800
    BorderColor = -1728053248
    BorderWidth = 1
    CornerRadius = 3
  end
  object PcgTag: TJucePanel
    Left = 28
    Top = 54
    Width = 60
    Height = 15
    Color = -14536642
    BorderWidth = 0
    CornerRadius = 2
  end
  object PcgTagText: TJuceLabel
    Left = 28
    Top = 54
    Width = 60
    Height = 15
    Caption = 'PCG'
    FontSize = 10.5
    Bold = True
    Color = -1447450
  end
  object OutTag: TJucePanel
    Left = 698
    Top = 54
    Width = 60
    Height = 15
    Color = -14536642
    BorderWidth = 0
    CornerRadius = 2
  end
  object OutTagText: TJuceLabel
    Left = 698
    Top = 54
    Width = 60
    Height = 15
    Caption = 'OUTPUT'
    FontSize = 10.5
    Bold = True
    Color = -1447450
  end
  object PatternLegend: TJuceLabel
    Left = 28
    Top = 75
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
    Top = 88
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
  object GainDisplay: TJuceDisplay
    Left = 80
    Top = 76
    Width = 230
    Height = 66
    Color = -15333882
    TextColor = -50398
    BorderColor = -16777216
    BorderWidth = 1
    CornerRadius = 2
  end
  object Mode: TJuceButton
    Left = 318
    Top = 76
    Width = 54
    Height = 46
    ParameterId = 'mode'
    Caption = 'MODE'
    ShowLed = False
    FaceColor = -15000803
    TextColor = -1447450
    CornerRadius = 3
  end
  object Rate: TJuceButton
    Left = 376
    Top = 76
    Width = 54
    Height = 46
    ParameterId = 'rate'
    Caption = 'RATE'
    ShowLed = False
    FaceColor = -15000803
    TextColor = -1447450
    CornerRadius = 3
  end
  object Depth: TJuceKnob
    Left = 438
    Top = 72
    Width = 54
    Height = 74
    ParameterId = 'depth'
    Caption = 'DEPTH'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Attack: TJuceKnob
    Left = 494
    Top = 72
    Width = 54
    Height = 74
    ParameterId = 'attack'
    Caption = 'ATK'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Hold: TJuceKnob
    Left = 550
    Top = 72
    Width = 54
    Height = 74
    ParameterId = 'hold'
    Caption = 'HOLD'
    ShowValue = False
    Sensitivity = 180
    TrackColor = -1447450
    BodyColor = -15394787
    PointerColor = -1082078
    TextColor = -1447450
    ValueBubble = jvbDragAndHover
  end
  object Decay: TJuceKnob
    Left = 606
    Top = 72
    Width = 54
    Height = 74
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
    Left = 698
    Top = 72
    Width = 56
    Height = 74
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
    Left = 754
    Top = 72
    Width = 56
    Height = 74
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
