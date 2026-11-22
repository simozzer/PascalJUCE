{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit pascaljuce_design;

{$warn 5023 off : no warning about unused units}
interface

uses
  JuceDesignRegLaz, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('JuceDesignRegLaz', @JuceDesignRegLaz.Register);
end;

initialization
  RegisterPackage('pascaljuce_design', @Register);
end.
