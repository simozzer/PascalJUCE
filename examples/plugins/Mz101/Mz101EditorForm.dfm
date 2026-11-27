object Mz101EditorForm: TMz101EditorForm
  Left = 0
  Top = 0
  Caption = 'Mz101_Pascal editor (design only)'
  ClientHeight = 610
  ClientWidth = 1490
  Color = 2301983
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object Theme: TJuceThemeResource
    Background = -14737373
    Panel = -13947856
    PanelBorder = -12829117
    Text = -1447450
    TextDim = -6644575
    Accent = -3000273
    Track = -16448251
    KnobBody = -11907239
    KnobPointer = -723465
    ButtonFace = -15329770
    LedOn = -2133654
    LedOff = -12970220
    MeterLow = -12596374
    MeterMid = -1521600
    MeterHigh = -1029574
    MeterBack = -16119286
    FontSize = 11
    TooltipBackground = -15658476
    TooltipText = -1447450
    TooltipBorder = -3000273
    MenuBackground = -13947856
    MenuText = -1447450
    MenuHighlight = -3000273
    MenuHighlightText = 0
    MenuHeader = 0
    BubbleBackground = -13947856
    BubbleText = -1447450
    BubbleBorder = -12829117
    BubbleFontSize = 15
    Link = -9785089
    Left = 8
    Top = 8
  end
  object NameStrip: TJucePanel
    Left = 0
    Top = 0
    Width = 1490
    Height = 4
    Color = -3000273
    BorderWidth = 0
    CornerRadius = 0
  end
  object Title: TJuceLabel
    Left = 16
    Top = 8
    Width = 120
    Height = 36
    Caption = 'Mz101'
    FontSize = 28
    Bold = True
    Alignment = jaLeft
  end
  object Subtitle: TJuceLabel
    Left = 112
    Top = 8
    Width = 300
    Height = 38
    Caption = 'MONOPHONIC SYNTHESIZER'
    FontSize = 12
    Alignment = jaLeft
    Color = -6644575
  end
  object ProjectLink: TJuceLink
    Left = 820
    Top = 12
    Width = 420
    Height = 26
    Hint = 'The project''s page: the latest version and what''s new in it, the source, and where to report a problem. Opens in your browser.'
    Caption = 'Mz101_Pascal 0.3.0  -  github.com/simozzer/Mz101'
    FontSize = 13
    Bold = True
    Alignment = jaRight
    Color = -9785089
    Url = 'https://github.com/simozzer/Mz101'
  end
  object PatchBox: TJuceComboBox
    Left = 1256
    Top = 12
    Width = 220
    Height = 26
    Hint = 'Factory patches. Your own edits are saved with the project.'
    ParameterId = 'patch'
    FontSize = 16
  end
  object ModulatorBox: TJucePanel
    Left = 14
    Top = 54
    Width = 322
    Height = 300
    Caption = 'MODULATOR'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object LfoRate: TJuceSlider
      Left = 8
      Top = 24
      Width = 42
      Height = 268
      Hint = 'MOD RATE'#10'Speed of the modulator (LFO): 0.1 to 30 Hz, or with SYNC on HOST a note length from 4 bars to 1/32. With CLOCK on INT it is also the arpeggio and sequencer''s tempo: one step per cycle.'#10'MIDI CC 76. Right-click to learn another.'
      Caption = 'RATE'
      ParameterId = 'lfoRate'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object LfoSync: TJuceSwitch
      Left = 50
      Top = 24
      Width = 66
      Height = 268
      Hint = 'MOD SYNC'#10'FREE: the modulator runs at RATE in hertz, as on the original. HOST: it locks to your DAW''s tempo and timeline, and RATE picks a note length. In the standalone app HOST falls back to FREE.'#10'MIDI CC 108. Right-click to learn another.'
      Caption = 'SYNC'
      ParameterId = 'lfoSync'
      Positions = 2
      Orientation = joVertical
      Labels = 'FREE|HOST'
      LeverColor = -15592942
      Style = jswSlide
    end
    object LfoWave: TJuceSwitch
      Left = 116
      Top = 24
      Width = 66
      Height = 268
      Hint = 'MOD WAVEFORM'#10'The modulator''s shape. RANDOM is a new random level on each clock; NOISE is the noise generator.'#10'MIDI CC 14. Right-click to learn another.'
      Caption = 'WAVE'
      ParameterId = 'lfoWave'
      Positions = 4
      Orientation = joVertical
      Labels = 'TRI|SQR|RAND|NOISE'
      LeverColor = -15592942
      Style = jswSlide
    end
    object ClockSource: TJuceSwitch
      Left = 182
      Top = 24
      Width = 66
      Height = 268
      Hint = 'CLOCK'#10'What steps the arpeggio and sequencer: the modulator (INT), or your DAW''s tempo and transport (HOST) - the EXT CLK jack. In the standalone app HOST falls back to INT.'#10'MIDI CC 106. Right-click to learn another.'
      Caption = 'CLOCK'
      ParameterId = 'clockSource'
      Positions = 2
      Orientation = joVertical
      Labels = 'INT|HOST'
      LeverColor = -15592942
      Style = jswSlide
    end
    object ClockDiv: TJuceSwitch
      Left = 248
      Top = 24
      Width = 66
      Height = 268
      Hint = 'CLOCK DIVISION'#10'With the clock on HOST: the length of each step, from quarter notes to 32nds (T = triplets).'#10'MIDI CC 107. Right-click to learn another.'
      Caption = 'DIV'
      ParameterId = 'clockDiv'
      Positions = 6
      Orientation = joVertical
      Labels = '1/4|1/8|1/8T|1/16|1/16T|1/32'
      LeverColor = -15592942
      Style = jswSlide
    end
  end
  object VcoBox: TJucePanel
    Left = 356
    Top = 54
    Width = 232
    Height = 300
    Caption = 'VCO'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object VcoMod: TJuceSlider
      Left = 8
      Top = 24
      Width = 42
      Height = 268
      Hint = 'VCO MOD'#10'How much the modulator moves the oscillator''s pitch: vibrato, trills, sirens.'#10'MIDI CC 77. Right-click to learn another.'
      Caption = 'MOD'
      ParameterId = 'vcoMod'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Range: TJuceSwitch
      Left = 50
      Top = 24
      Width = 66
      Height = 268
      Hint = 'VCO RANGE'#10'Oscillator octave, as organ footage: 16'' is lowest, 2'' highest.'#10'MIDI CC 15. Right-click to learn another.'
      Caption = 'RANGE'
      ParameterId = 'range'
      Positions = 4
      Orientation = joVertical
      Labels = '16''|8''|4''|2'''
      LeverColor = -15592942
      Style = jswSlide
    end
    object Pw: TJuceSlider
      Left = 116
      Top = 24
      Width = 42
      Height = 268
      Hint = 'PULSE WIDTH'#10'Pulse width - or how far PWM moves it. 0 is a square (50%); 10 narrows it to nothing.'#10'MIDI CC 16. Right-click to learn another.'
      Caption = 'PW / PWM'
      ParameterId = 'pw'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object PwmSource: TJuceSwitch
      Left = 158
      Top = 24
      Width = 66
      Height = 268
      Hint = 'PWM SOURCE'#10'What sets the pulse width: the modulator (LFO), the PW slider alone (MAN), or the envelope (ENV).'#10'MIDI CC 17. Right-click to learn another.'
      Caption = 'PWM'
      ParameterId = 'pwmSource'
      Positions = 3
      Orientation = joVertical
      Labels = 'LFO|MAN|ENV'
      LeverColor = -15592942
      Style = jswSlide
    end
  end
  object MixerBox: TJucePanel
    Left = 608
    Top = 54
    Width = 250
    Height = 300
    Caption = 'SOURCE MIXER'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object Pulse: TJuceSlider
      Left = 8
      Top = 24
      Width = 42
      Height = 268
      Hint = 'PULSE LEVEL'#10'Level of the pulse wave into the filter.'#10'MIDI CC 18. Right-click to learn another.'
      Caption = 'PULSE'
      ParameterId = 'pulse'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Saw: TJuceSlider
      Left = 50
      Top = 24
      Width = 42
      Height = 268
      Hint = 'SAW LEVEL'#10'Level of the sawtooth into the filter.'#10'MIDI CC 19. Right-click to learn another.'
      Caption = 'SAW'
      ParameterId = 'saw'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Sub: TJuceSlider
      Left = 92
      Top = 24
      Width = 42
      Height = 268
      Hint = 'SUB LEVEL'#10'Level of the sub oscillator, locked to the main one below it.'#10'MIDI CC 20. Right-click to learn another.'
      Caption = 'SUB OSC'
      ParameterId = 'sub'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object SubType: TJuceSwitch
      Left = 134
      Top = 24
      Width = 66
      Height = 268
      Hint = 'SUB WAVEFORM'#10'Sub oscillator: square one octave down, square two down, or narrow pulse two down.'#10'MIDI CC 21. Right-click to learn another.'
      Caption = 'SUB'
      ParameterId = 'subType'
      Positions = 3
      Orientation = joVertical
      Labels = '-1 OCT|-2 OCT|-2 PW'
      LeverColor = -15592942
      Style = jswSlide
    end
    object Noise: TJuceSlider
      Left = 200
      Top = 24
      Width = 42
      Height = 268
      Hint = 'NOISE LEVEL'#10'Level of white noise into the filter.'#10'MIDI CC 22. Right-click to learn another.'
      Caption = 'NOISE'
      ParameterId = 'noise'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
  end
  object VcfBox: TJucePanel
    Left = 878
    Top = 54
    Width = 226
    Height = 300
    Caption = 'VCF'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object Cutoff: TJuceSlider
      Left = 8
      Top = 24
      Width = 42
      Height = 268
      Hint = 'VCF FREQ'#10'Filter cutoff, 10 Hz to 20 kHz. Lower is darker.'#10'MIDI CC 74. Right-click to learn another.'
      Caption = 'FREQ'
      ParameterId = 'cutoff'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Res: TJuceSlider
      Left = 50
      Top = 24
      Width = 42
      Height = 268
      Hint = 'VCF RES'#10'Filter resonance. Emphasises the cutoff; near the top the filter whistles on its own.'#10'MIDI CC 71. Right-click to learn another.'
      Caption = 'RES'
      ParameterId = 'res'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object VcfEnv: TJuceSlider
      Left = 92
      Top = 24
      Width = 42
      Height = 268
      Hint = 'VCF ENV'#10'How far the envelope opens the filter on each note.'#10'MIDI CC 23. Right-click to learn another.'
      Caption = 'ENV'
      ParameterId = 'vcfEnv'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object VcfMod: TJuceSlider
      Left = 134
      Top = 24
      Width = 42
      Height = 268
      Hint = 'VCF MOD'#10'How much the modulator moves the filter cutoff.'#10'MIDI CC 24. Right-click to learn another.'
      Caption = 'MOD'
      ParameterId = 'vcfMod'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object VcfKybd: TJuceSlider
      Left = 176
      Top = 24
      Width = 42
      Height = 268
      Hint = 'VCF KYBD'#10'How much the cutoff follows the keyboard. 10 tracks it exactly - play a whistling filter in tune.'#10'MIDI CC 25. Right-click to learn another.'
      Caption = 'KYBD'
      ParameterId = 'vcfKybd'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
  end
  object VcaBox: TJucePanel
    Left = 1124
    Top = 54
    Width = 82
    Height = 300
    Caption = 'VCA'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object VcaMode: TJuceSwitch
      Left = 8
      Top = 24
      Width = 66
      Height = 268
      Hint = 'VCA MODE'#10'What shapes the volume: the envelope (ENV), or simply on while a key is held (GATE).'#10'MIDI CC 26. Right-click to learn another.'
      Caption = 'MODE'
      ParameterId = 'vcaMode'
      Positions = 2
      Orientation = joVertical
      Labels = 'ENV|GATE'
      LeverColor = -15592942
      Style = jswSlide
    end
  end
  object EnvBox: TJucePanel
    Left = 1226
    Top = 54
    Width = 250
    Height = 300
    Caption = 'ENV'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object Attack: TJuceSlider
      Left = 8
      Top = 24
      Width = 42
      Height = 268
      Hint = 'ENV ATTACK'#10'Envelope attack time, 1.5 ms to 4 s.'#10'MIDI CC 73. Right-click to learn another.'
      Caption = 'A'
      ParameterId = 'attack'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Decay: TJuceSlider
      Left = 50
      Top = 24
      Width = 42
      Height = 268
      Hint = 'ENV DECAY'#10'Envelope decay time down to the sustain level, 2 ms to 10 s.'#10'MIDI CC 75. Right-click to learn another.'
      Caption = 'D'
      ParameterId = 'decay'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Sustain: TJuceSlider
      Left = 92
      Top = 24
      Width = 42
      Height = 268
      Hint = 'ENV SUSTAIN'#10'Level the envelope holds at while a key stays down.'#10'MIDI CC 79. Right-click to learn another.'
      Caption = 'S'
      ParameterId = 'sustain'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Release: TJuceSlider
      Left = 134
      Top = 24
      Width = 42
      Height = 268
      Hint = 'ENV RELEASE'#10'Envelope release time after the key is let go, 2 ms to 10 s.'#10'MIDI CC 72. Right-click to learn another.'
      Caption = 'R'
      ParameterId = 'release'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object EnvTrig: TJuceSwitch
      Left = 176
      Top = 24
      Width = 66
      Height = 268
      Hint = 'ENV TRIGGER'#10'When the envelope restarts: every new key (G+T), only after all keys are up (GATE), or on every modulator cycle (LFO).'#10'MIDI CC 27. Right-click to learn another.'
      Caption = 'TRIG'
      ParameterId = 'envTrig'
      Positions = 3
      Orientation = joVertical
      Labels = 'G+T|GATE|LFO'
      LeverColor = -15592942
      Style = jswSlide
    end
  end
  object PortamentoBox: TJucePanel
    Left = 14
    Top = 366
    Width = 124
    Height = 230
    Caption = 'PORTAMENTO'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object PortaMode: TJuceSwitch
      Left = 8
      Top = 24
      Width = 66
      Height = 198
      Hint = 'PORTAMENTO'#10'Glide between notes: never, only when keys overlap (AUTO), or always.'#10'MIDI CC 65. Right-click to learn another.'
      Caption = 'MODE'
      ParameterId = 'portaMode'
      Positions = 3
      Orientation = joVertical
      Labels = 'OFF|AUTO|ON'
      LeverColor = -15592942
      Style = jswSlide
    end
    object PortaTime: TJuceSlider
      Left = 74
      Top = 24
      Width = 42
      Height = 198
      Hint = 'PORTAMENTO TIME'#10'Glide time, up to 5 s.'#10'MIDI CC 5. Right-click to learn another.'
      Caption = 'TIME'
      ParameterId = 'portaTime'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
  end
  object BenderBox: TJucePanel
    Left = 146
    Top = 366
    Width = 142
    Height = 230
    Caption = 'BENDER'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object BendVco: TJuceSlider
      Left = 8
      Top = 24
      Width = 42
      Height = 198
      Hint = 'BENDER VCO'#10'How far the pitch wheel bends the oscillator, up to an octave.'#10'MIDI CC 28. Right-click to learn another.'
      Caption = 'VCO'
      ParameterId = 'bendVco'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object BendVcf: TJuceSlider
      Left = 50
      Top = 24
      Width = 42
      Height = 198
      Hint = 'BENDER VCF'#10'How far the pitch wheel moves the filter cutoff.'#10'MIDI CC 29. Right-click to learn another.'
      Caption = 'VCF'
      ParameterId = 'bendVcf'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object ModDepth: TJuceSlider
      Left = 92
      Top = 24
      Width = 42
      Height = 198
      Hint = 'BENDER MOD'#10'How much vibrato the mod wheel (CC 1) brings in.'#10'MIDI CC 30. Right-click to learn another.'
      Caption = 'MOD'
      ParameterId = 'modDepth'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
  end
  object ArpeggioBox: TJucePanel
    Left = 296
    Top = 366
    Width = 138
    Height = 230
    Caption = 'ARPEGGIO'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object ArpMode: TJuceSwitch
      Left = 8
      Top = 24
      Width = 66
      Height = 198
      Hint = 'ARPEGGIO'#10'Arpeggiator: plays the held keys in turn, at the modulator''s rate.'#10'MIDI CC 102. Right-click to learn another.'
      Caption = 'MODE'
      ParameterId = 'arpMode'
      Positions = 4
      Orientation = joVertical
      Labels = 'OFF|UP|U&D|DOWN'
      LeverColor = -15592942
      Style = jswSlide
    end
    object ArpHold: TJuceButton
      Left = 78
      Top = 60
      Width = 48
      Height = 40
      Hint = 'HOLD'#10'Keeps the arpeggio or sequence running after the keys are let go. Also the sustain pedal.'#10'MIDI CC 64. Right-click to learn another.'
      Caption = 'HOLD'
      ParameterId = 'arpHold'
      LedPosition = jlpTop
      Flat = True
      CornerRadius = 3
    end
  end
  object SequencerBox: TJucePanel
    Left = 442
    Top = 366
    Width = 162
    Height = 230
    Caption = 'SEQUENCER'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object SeqMode: TJuceSwitch
      Left = 8
      Top = 24
      Width = 66
      Height = 198
      Hint = 'SEQUENCER'#10'PLAY runs the sequence while a key is held (the key transposes it). LOAD records a new one.'#10'MIDI CC 103. Right-click to learn another.'
      Caption = 'MODE'
      ParameterId = 'seqMode'
      Positions = 3
      Orientation = joVertical
      Labels = 'OFF|PLAY|LOAD'
      LeverColor = -15592942
      Style = jswSlide
    end
    object TransRest: TJuceButton
      Left = 78
      Top = 60
      Width = 72
      Height = 40
      Hint = 'KEY TRANSPOSE: press, then a key - the shift from middle C moves the VCO. In LOAD: enter a rest'
      Caption = 'TRANS/REST'
      Mode = jbmMomentary
      LedPosition = jlpTop
      LedMeterIndex = 0
      Flat = True
      CornerRadius = 3
    end
    object Legato: TJuceButton
      Left = 78
      Top = 110
      Width = 72
      Height = 40
      Hint = 'In LOAD: tie the next note to this one - no new envelope, and it glides with portamento AUTO'
      Caption = 'LEGATO'
      Mode = jbmMomentary
      LedPosition = jlpTop
      LedMeterIndex = 1
      Flat = True
      CornerRadius = 3
    end
    object StepReadout: TJuceDisplay
      Left = 78
      Top = 188
      Width = 72
      Height = 28
      Caption = '0 STEPS'
      Color = -16119286
      TextColor = -2333089
      CornerRadius = 3
      FontName = 'Lucida Console'
      FontSize = 12
      Bold = True
    end
  end
  object KeyBox: TJucePanel
    Left = 612
    Top = 366
    Width = 82
    Height = 230
    Caption = 'KEY'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object Transpose: TJuceSwitch
      Left = 8
      Top = 24
      Width = 66
      Height = 198
      Hint = 'TRANSPOSE'#10'Moves the keyboard down an octave (L), or up one (H).'#10'MIDI CC 104. Right-click to learn another.'
      Caption = 'TRANS'
      ParameterId = 'transpose'
      Positions = 3
      Orientation = joVertical
      Labels = 'L|M|H'
      LeverColor = -15592942
      Style = jswSlide
    end
  end
  object MasterBox: TJucePanel
    Left = 702
    Top = 366
    Width = 100
    Height = 230
    Caption = 'MASTER'
    BorderWidth = 1
    CornerRadius = 4
    HeaderHeight = 24
    CaptionAlign = jaCenter
    CaptionSeparator = True
    object Tune: TJuceSlider
      Left = 8
      Top = 24
      Width = 42
      Height = 198
      Hint = 'TUNE'#10'Fine tuning, +-50 cents.'#10'MIDI CC 105. Right-click to learn another.'
      Caption = 'TUNE'
      ParameterId = 'tune'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
    object Volume: TJuceSlider
      Left = 50
      Top = 24
      Width = 42
      Height = 198
      Hint = 'VOLUME'#10'Output level.'#10'MIDI CC 7. Right-click to learn another.'
      Caption = 'VOL'
      ParameterId = 'volume'
      ShowValue = False
      ThumbColor = -2565932
      Style = jslFader
      JumpToClick = True
      ValueBubble = jvbDragAndHover
    end
  end
  object KeyboardBox: TJucePanel
    Left = 810
    Top = 366
    Width = 666
    Height = 230
    BorderWidth = 1
    CornerRadius = 4
    object Keyboard: TJuceKeyboard
      Left = 8
      Top = 24
      Width = 650
      Height = 198
      FirstNote = 41
      LastNote = 72
      OctaveForMiddleC = 4
    end
  end
end
