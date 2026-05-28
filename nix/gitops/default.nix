# nix/gitops/default.nix
#
# GitOps manifest generator.
# Generates Kubernetes YAML manifests from Nix using nixidy-style patterns.
# Output: nix build .#k8s-manifests -> result/ directory of YAML files
#
# Each manifest entry is one of two shapes:
#   { name = "ns/file.yaml"; content = "..."; }        # inline string
#   { name = "ns/file.yaml"; source  = <path|drv>; }   # file copied from Nix store
#
# The `source` form lets helm-template outputs flow through to rendered/
# without going via a Nix string (which would IFD-load the contents).
#
{ pkgs, lib, secrets ? null, nixidy ? null }:
let
  envDir = ./env;
  helm = import ./helm-chart.nix { inherit pkgs lib; };

  # Fallback secrets stub for the case where ./secrets/ doesn't exist
  # — keeps the manifest derivation buildable even without a key.
  emptySecrets = {
    cephClientSecret = null;
    cephKeyringPath = null;
    cephConf = null;
  };
  secrets' = if secrets == null then emptySecrets else secrets;

  # Import environment modules.
  base          = import (envDir + "/base.nix")           { inherit pkgs lib; };
  argocd        = import (envDir + "/argocd.nix")         { inherit pkgs lib helm; };
  cilium        = import (envDir + "/cilium.nix")         { inherit pkgs lib helm; };
  certManager   = import (envDir + "/cert-manager.nix")   { inherit pkgs lib; };
  rookOperator  = import (envDir + "/rook-operator.nix")  { inherit pkgs lib helm; };
  rookCluster   = import (envDir + "/rook-cluster.nix")   { inherit pkgs lib helm; };
  cephDemo      = import (envDir + "/ceph-demo.nix")      { inherit pkgs lib; };
  cephExternalClient = import (envDir + "/ceph-external-client.nix") {
    inherit pkgs lib;
    secrets = secrets';
  };

  # Combine all manifests
  allManifests = base.manifests
    ++ argocd.manifests
    ++ cilium.manifests
    ++ certManager.manifests
    ++ rookOperator.manifests
    ++ rookCluster.manifests
    ++ cephDemo.manifests
    ++ cephExternalClient.manifests;

  emitStep = m:
    if m ? source then ''
      mkdir -p "$out/$(dirname "${m.name}")"
      cp "${m.source}" "$out/${m.name}"
      chmod u+w "$out/${m.name}"
    '' else ''
      mkdir -p "$out/$(dirname "${m.name}")"
      cat > "$out/${m.name}" <<'MANIFEST_EOF'
      ${m.content}
      MANIFEST_EOF
    '';

  manifestDerivation = pkgs.runCommand "k8s-manifests" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" emitStep allManifests}
    echo "Generated ${toString (builtins.length allManifests)} manifests" > $out/README
  '';
in
{
  packages = {
    k8s-manifests = manifestDerivation;
  };
}
