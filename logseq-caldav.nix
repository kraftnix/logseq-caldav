{
  lib,
  difftastic,
  vdirsyncer,
  nushell,
  writeTextFile
}:
let
  name = "logseq-caldav";
  version = "0.0.1";
in
writeTextFile {
  name = "${name}-${version}";
  destination = "/bin/${name}";
  executable = true;
  text = ''
    #!${lib.getExe nushell}

    $env.PATH = ($env.PATH | append "${lib.makeBinPath [ difftastic vdirsyncer ]}" | str join ":")

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
