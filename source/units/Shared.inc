{$mode delphi} {$H+}
{$M+}
{$IFDEF PRODUCTION}
  {$optimization autoInline}
  {$overflowchecks off}
  {$rangechecks off}
  {$S-}
  {$OBJECTCHECKS OFF}
  {$C-}
{$ELSE}
  {$overflowchecks on}
  {$rangechecks on}
  {$S+}
  {$OBJECTCHECKS ON}
  {$C+}
{$ENDIF}
{$modeswitch advancedrecords}
{ Typed constants are read-only. Delphi mode defaults them writable, which
  would make constants like WASM_MAGIC mutable globals. }
{$J-}
