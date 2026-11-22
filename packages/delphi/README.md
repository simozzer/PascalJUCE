# PascalJUCE packages for Delphi

**Status: written, not compiled.** No Delphi was available when these were
made, so they have not been built or installed even once. The code sticks
to Delphi 10.x syntax and the units it shares with the Lazarus packages
(`pascal/design/*.pas`, generated `JuceDesignGen.inc`) are compiled and
tested with Free Pascal/LCL on every ctest run; the Delphi-only parts
(`{$ELSE}` branches using the VCL, and `JuceDesignRegVcl.pas` with
DesignIntf/ToolsAPI) are the untested ones. Please report what the compiler
says.

| Package | Kind | Contents |
|---|---|---|
| `PascalJUCE_VCL.dpk` | run time (`{$RUNONLY}`) | the run-time plug-in units the controls wrap, the TCanvas back end (`JuceRaster`, `JuceTCanvas`) and the designer controls (`JuceDesignControls`) |
| `PascalJUCE_Design.dpk` | design time (`{$DESIGNONLY}`) | `JuceDesignRegVcl.pas`: palette page "PascalJUCE", property editors (ParameterId drop-down, colours, image names, image file) |

## Install

1. Open `PascalJUCE_VCL.dpk`, choose the **Win32** platform (the IDE is a
   32-bit process; this package is for the IDE only, your Win64 plug-in
   never uses it) and *Build*. If `Classes`, `SysUtils` or similar are not
   found, add `System;Vcl;Vcl.Imaging;Winapi` to *Project ▸ Options ▸
   Building ▸ Delphi Compiler ▸ Unit scope names*.
2. Open `PascalJUCE_Design.dpk`, *Build*, then right-click it in the
   Projects window and *Install*. A **PascalJUCE** palette page appears.

The IDE writes `.dproj` and `.res` files next to the packages on first open;
that is expected.

Then follow "Designing a panel in Lazarus or Delphi" in
[docs/PLUGINS.md](../../docs/PLUGINS.md): design a form, embed its `.dfm` with
`{$R YourForm.dfm}` in the plug-in's editor unit, and load it with
`JuceLoadLayoutResource(Self, 'TYourForm')`.
