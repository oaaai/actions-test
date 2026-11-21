#!/usr/bin/env bash
# plan.sh: build the Actions plan with standard tools only.
#
#   bash actions/plan.sh <bundle> <channel> [out]
#
# Tools: curl, yq (mikefarah), jq, skopeo, and the official eksctl-anywhere CLI.
# No custom YAML parser, no custom HTTP downloader, no Python.
set -euo pipefail

BUNDLE=${1:?usage: plan.sh <bundle> <channel> [out]}
CHANNEL=${2:?usage: plan.sh <bundle> <channel> [out]}
OUT=${3:-plan}
KUBE=${CHANNEL/-/.}

for tool in curl yq jq skopeo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required" >&2
    exit 2
  }
done

mkdir -p "$OUT"
OUT_ABS=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() {
  curl -fsSL --retry 5 --retry-delay 2 "$1" -o "$2"
}

# --- EKS-A release / bundle / EKS-D -----------------------------------------

REL="$OUT/eks-a-release.yaml"
fetch "https://anywhere-assets.eks.amazonaws.com/releases/eks-a/manifest.yaml" "$REL"

BUNDLE_URL=$(yq -r ".spec.releases[] | select(.number == $BUNDLE) | .bundleManifestUrl" "$REL")
CLI_URL=$(yq -r ".spec.releases[] | select(.number == $BUNDLE) | .eksACLI.linux.amd64.uri" "$REL")
EKS_A_VERSION=$(yq -r ".spec.releases[] | select(.number == $BUNDLE) | .version" "$REL")
if [ -z "$BUNDLE_URL" ] || [ "$BUNDLE_URL" = "null" ]; then
  echo "ERROR: bundle $BUNDLE not found in the release manifest" >&2
  exit 2
fi

BUNDLE_YAML="$OUT/bundle.yaml"
fetch "$BUNDLE_URL" "$BUNDLE_YAML"

vb() {
  yq -r ".spec.versionsBundles[] | select(.kubeVersion == \"$KUBE\") | $1" "$BUNDLE_YAML"
}

EKSD_URL=$(vb '.eksD.manifestUrl')
if [ -z "$EKSD_URL" ] || [ "$EKSD_URL" = "null" ]; then
  echo "ERROR: channel $CHANNEL not found in bundle $BUNDLE" >&2
  exit 2
fi

EKSD="$OUT/eks-d.yaml"
fetch "$EKSD_URL" "$EKSD"

# --- admin (eksctl-anywhere / kubectl) + HookOS ------------------------------

CLI_TGZ="$WORK/eksctl-anywhere.tar.gz"
fetch "$CLI_URL" "$CLI_TGZ"
CLI_DIR="$WORK/cli"
mkdir -p "$CLI_DIR"
tar xzf "$CLI_TGZ" -C "$CLI_DIR"
CLI="$CLI_DIR/eksctl-anywhere"
chmod +x "$CLI"

mkdir -p "$OUT/eksctl-anywhere/$EKS_A_VERSION"
cp "$CLI_TGZ" "$OUT/eksctl-anywhere/$EKS_A_VERSION/$(basename "$CLI_URL")"

KUBECTL_URL=$(yq -r '.status.components[] | select(.name == "kubernetes") | .assets[] | select(.name == "bin/linux/amd64/kubectl") | .archive.uri' "$EKSD")
mkdir -p "$OUT/kubectl/$KUBE"
fetch "$KUBECTL_URL" "$OUT/kubectl/$KUBE/kubectl"
chmod +x "$OUT/kubectl/$KUBE/kubectl"

VMLINUZ_URL=$(vb '.tinkerbell.tinkerbellStack.hook.vmlinuz.amd.uri')
INITRAMFS_URL=$(vb '.tinkerbell.tinkerbellStack.hook.initramfs.amd.uri')
HOOK_COMMIT=$(basename "$(dirname "$VMLINUZ_URL")")
mkdir -p "$OUT/hookos/$HOOK_COMMIT"
fetch "$VMLINUZ_URL" "$OUT/hookos/$HOOK_COMMIT/vmlinuz-x86_64"
fetch "$INITRAMFS_URL" "$OUT/hookos/$HOOK_COMMIT/initramfs-x86_64"

# --- cluster manifests: official CLI (no custom downloader) ------------------

export EKSCTL_VERSION=${EKSCTL_VERSION:-0.231.0}
# Run from $OUT with a RELATIVE download dir: the official CLI writes the
# directory path into the tarball header, so an absolute path would break the
# official layout that b-tool expects.
(
  cd "$OUT"
  "$CLI" download artifacts \
    --bundles-override "$OUT_ABS/bundle.yaml" \
    --download-dir eks-anywhere-downloads
)

# --- image / chart / package lists (yq + jq + skopeo) -----------------------

CHARTS="$WORK/charts.tsv"
yq -r ".spec.versionsBundles[] | select(.kubeVersion == \"$KUBE\") | [.cilium.helmChart, .packageController.helmChart, .tinkerbell.tinkerbellStack.tinkerbellChart, .tinkerbell.tinkerbellStack.tinkerbellCrds, .tinkerbell.tinkerbellStack.stack] | .[] | select(.uri) | [.uri, .imageDigest] | @tsv" "$BUNDLE_YAML" > "$CHARTS"

BUNDLE_IMAGES="$WORK/bundle-images.tsv"
yq -r ".spec.versionsBundles[] | select(.kubeVersion == \"$KUBE\") | .. | select(tag == \"!!map\" and has(\"imageDigest\")) | [.uri, .imageDigest] | @tsv" "$BUNDLE_YAML" > "$BUNDLE_IMAGES"
awk -F'\t' 'NR==FNR{chart[$1]=1;next} !($1 in chart)' "$CHARTS" "$BUNDLE_IMAGES" > "$WORK/bundle-only.tsv"

yq -r '.status.components[].assets[] | select(.image) | [.image.uri, (.image.imageDigest // "")] | @tsv' "$EKSD" > "$WORK/eksd.tsv"

awk -F'\t' -v OFS='\t' '{print $1, $2, "eks-a"}' "$WORK/bundle-only.tsv" > "$WORK/rows.tsv"
awk -F'\t' -v OFS='\t' '{print $1, $2, "eks-d"}' "$WORK/eksd.tsv" >> "$WORK/rows.tsv"
awk -F'\t' '!seen[$1]++' "$WORK/rows.tsv" > "$WORK/rows-unique.tsv"

: > "$WORK/resolved.tsv"
while IFS=$'\t' read -r uri digest source; do
  if [ -z "$digest" ]; then
    digest=$(skopeo inspect --format '{{.Digest}}' "docker://$uri")
  fi
  printf '%s\t%s\t%s\n' "$uri" "$digest" "$source" >> "$WORK/resolved.tsv"
done < "$WORK/rows-unique.tsv"

{
  printf '# tar\tref\tdigest\tsource\tplatform\n'
  awk -F'\t' -v OFS='\t' '{name=$1; gsub(/[^A-Za-z0-9._-]+/, "_", name); print name ".tar", $1, $2, $3, "linux/amd64"}' "$WORK/resolved.tsv"
} > "$OUT/images.tsv"

{
  printf '# file\tref\tdigest\n'
  awk -F'\t' -v OFS='\t' '{name=$1; gsub(/[^A-Za-z0-9._-]+/, "_", name); print name ".tgz", $1, $2}' "$CHARTS"
} > "$OUT/charts.tsv"

PKG_URI=$(vb '.packageController.packageController.uri')
PKG_REG=$(printf '%s' "$PKG_URI" | cut -d/ -f1)
PKG_NS=$(printf '%s' "$PKG_URI" | cut -d/ -f2)
PKG_REF="$PKG_REG/$PKG_NS/eks-anywhere-packages-bundles:v$CHANNEL-latest"
PKG_DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://$PKG_REF")
PKG_FILE=$(printf '%s' "$PKG_REF" | sed 's/[^A-Za-z0-9._-]/_/g').yaml
{
  printf '# file\tref\tdigest\n'
  printf '%s\t%s\t%s\n' "$PKG_FILE" "$PKG_REF" "$PKG_DIGEST"
} > "$OUT/packages.tsv"

IMAGE_BUILDER=$(vb '.eksD.imagebuilder.uri' | sed -E 's#.*/image-builder/(v[^/]+)/.*#\1#')
IMAGES=$(grep -vc '^#' "$OUT/images.tsv" || true)
CHARTS_N=$(grep -vc '^#' "$OUT/charts.tsv" || true)
PACKAGES=$(grep -vc '^#' "$OUT/packages.tsv" || true)
jq -n \
  --argjson bundle "$BUNDLE" \
  --arg channel "$CHANNEL" \
  --arg kube "$KUBE" \
  --arg eksa "$EKS_A_VERSION" \
  --arg ib "$IMAGE_BUILDER" \
  --argjson images "$IMAGES" \
  --argjson charts "$CHARTS_N" \
  --argjson packages "$PACKAGES" \
  '{bundle: $bundle, channel: $channel, channels: [$channel], kubeVersion: $kube,
    eksaVersion: $eksa, imageBuilder: $ib,
    counts: {images: $images, charts: $charts, packages: $packages}}' > "$OUT/plan.json"

echo "plan: $OUT (images=$IMAGES charts=$CHARTS_N packages=$PACKAGES)"