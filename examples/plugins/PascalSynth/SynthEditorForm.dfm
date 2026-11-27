object SynthEditorForm: TSynthEditorForm
  Left = 0
  Top = 0
  Caption = 'Pascal Synth editor (design only)'
  ClientHeight = 300
  ClientWidth = 480
  Color = 2367518
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object MainPanel: TJucePanel
    Left = 6
    Top = 6
    Width = 468
    Height = 288
    Caption = 'PASCAL SYNTH'
    Color = -13618117
    GradientColor = -14473685
    object Wave: TJuceSwitch
      Left = 16
      Top = 60
      Width = 150
      Height = 64
      Hint = 'Oscillator waveform'
      Caption = 'WAVE'
      ParameterId = 'wave'
      Positions = 3
      Labels = 'Sine|Saw|Square'
    end
    object Attack: TJuceKnob
      Left = 180
      Top = 44
      Width = 76
      Height = 104
      Hint = 'Attack time'
      Caption = 'ATTACK'
      ParameterId = 'attack'
    end
    object Release: TJuceKnob
      Left = 262
      Top = 44
      Width = 76
      Height = 104
      Hint = 'Release time'
      Caption = 'RELEASE'
      ParameterId = 'release'
    end
    object Gain: TJuceKnob
      Left = 344
      Top = 44
      Width = 76
      Height = 104
      Hint = 'Output level'
      Caption = 'GAIN'
      ParameterId = 'gain'
    end
    object OutMeter: TJuceMeter
      Left = 436
      Top = 36
      Width = 14
      Height = 132
      Hint = 'Output peak'
    end
    object OutLabel: TJuceLabel
      Left = 416
      Top = 170
      Width = 54
      Height = 18
      Caption = 'OUT'
      FontSize = 11.000000000000000000
      Color = -6643542
    end
    object OutScope: TJuceScope
      Left = 16
      Top = 196
      Width = 364
      Height = 80
      Hint = 'The output, triggered on a rising zero crossing'
    end
    object ScopeTime: TJuceKnob
      Left = 388
      Top = 190
      Width = 64
      Height = 92
      Hint = 'How much the scope shows: 1 to 170 ms'
      Caption = 'TIME'
      DefaultValue = 0.5833
    end
    object HelpLabel: TJuceLabel
      Left = 16
      Top = 170
      Width = 300
      Height = 18
      Caption = 'Drag: change   Shift: fine   Double-click: default'
      FontSize = 11.000000000000000000
      Alignment = jaLeft
      Color = -6643542
    end
  end
end
