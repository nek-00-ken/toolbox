{ sources ? import ./nix/sources.nix
, nixpkgs ? sources.nixpkgs
, pkgs ? import nixpkgs {}
}:

let

  terraform-provider-keycloak = pkgs.callPackage ./pkgs/terraform-provider-keycloak.nix
    { source = sources.terraform-provider-keycloak; };

in {

  inherit (pkgs) ansible kubectl stern vault docker-compose fly;

  helm = pkgs.kubernetes-helm;

  terraform = pkgs.terraform_0_12.withPlugins (p: [
    p.local p.openstack p.vault terraform-provider-keycloak
  ]);

  safe = pkgs.callPackage ./pkgs/safe.nix
    { source = sources.safe; };

}
