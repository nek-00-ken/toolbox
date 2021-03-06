{
  stdenv,
  source,
  makeWrapper,
  terraform
}:
stdenv.mkDerivation rec {
  pname = "tf";
  version = source.version;
  src = source.outPath;

  buildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp tf $out/bin/
    chmod +x $out/bin/tf
    wrapProgram $out/bin/tf --prefix PATH ":" ${terraform}/bin
  '';

  meta = with stdenv.lib; {
    description = "wrapper around terraform";
    homepage = "https://github.com/Caascad/tf";
    license = licenses.mit;
    maintainers = with maintainers; [ "Benjile" ];
  };

}
