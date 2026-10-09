{
  lib,
  difftastic,
  vdirsyncer,
  pimsync,
  nushell,
  nushellPlugins,
  writeTextFile
}:
let
  name = "logseq-caldav";
  version = "1.0.0";
in
writeTextFile {
  name = "${name}-${version}";
  destination = "/bin/${name}";
  executable = true;
  text = ''
    #!/usr/bin/env -S ${lib.getExe nushell} -n --plugins ['${lib.getExe nushellPlugins.formats}']

    $env.PATH = ($env.PATH | append "${lib.makeBinPath [ difftastic vdirsyncer pimsync ]}" | str join ":")

    ${(builtins.readFile ./logseq-caldav.nu)}
  '';
  derivationArgs = {
    pname = name;
    inherit version;
  };
  meta = {
    description = "a tool to generate CalDAV Tasks and Calendar events from Logseq Tasks using Logseq's HTTP API";
    homepage = "https://github.com/kraftnix/logseq-caldav";
    maintainers = with lib.maintainers; [ kraftnix ];
    mainProgram = name;
  };
}
