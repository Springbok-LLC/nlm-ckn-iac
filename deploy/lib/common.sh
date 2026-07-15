# ==============================================================================
# deploy/lib/common.sh — shared constants for the deploy scripts
# ==============================================================================
# Source this from every deploy script:
#
#   source "$(dirname "$0")/lib/common.sh"          # scripts that cd afterwards
#   source "${SCRIPT_DIR}/lib/common.sh"            # scripts with SCRIPT_DIR set
#
# PROJECT_NAME is the single source of truth for the project namespace. Every
# stack in the nlm-ckn flow declares ProjectName as a *required* parameter (no
# template default); the scripts inject this value into each deployment. To use
# a different namespace for a one-off run, export PROJECT_NAME before invoking.
# ==============================================================================

: "${PROJECT_NAME:=nlm-ckn}"

# ──────────────────────────────────────────────────────────────────────────────
# ecr_image_exists REPO_NAME TAG REGION   → 0 if the tagged image exists, else 1
# ──────────────────────────────────────────────────────────────────────────────
ecr_image_exists() {
  local repo="$1" tag="$2" region="$3"
  aws ecr describe-images \
    --repository-name "${repo}" \
    --image-ids "imageTag=${tag}" \
    --region "${region}" >/dev/null 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# wait_for_ecr_image REPO_NAME TAG REGION
#
# The IaC deploy scripts do NOT build container images — images are built and
# pushed by the nlm-ckn-etl repo's CI (.github/workflows/build-image.yml). This
# helper confirms the image the stack is about to reference exists. If it does
# not, it prints copy/re-tag guidance (no rebuild needed) and pauses, letting the
# user push the image in another shell, then re-checks when they press Enter.
# ──────────────────────────────────────────────────────────────────────────────
wait_for_ecr_image() {
  local repo="$1" tag="$2" region="$3"

  while ! ecr_image_exists "${repo}" "${tag}" "${region}"; do
    # Existing tags in the repo — suggest a source for a server-side re-tag.
    local existing src_tag registry
    existing=$(aws ecr describe-images \
      --repository-name "${repo}" --region "${region}" \
      --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].imageTags[]' \
      --output text 2>/dev/null | tr '\t' ' ') || true
    src_tag="${existing%% *}"

    registry=$(aws ecr describe-repositories \
      --repository-names "${repo}" --region "${region}" \
      --query 'repositories[0].repositoryUri' --output text 2>/dev/null) || true
    registry="${registry%%/*}"

    {
      echo
      echo "Image ${repo}:${tag} was not found in ECR."
      echo "It does NOT need rebuilding — it is built and pushed by the nlm-ckn-etl"
      echo "repo's CI (.github/workflows/build-image.yml). Push it now, then continue."
      echo
      echo "  Existing tags in ${repo}: ${existing:-<none>}"
      echo
      echo "  A) Re-point tag '${tag}' at an existing image (server-side, no pull/push):"
      if [[ -n "${src_tag}" ]]; then
        echo "       MANIFEST=\$(aws ecr batch-get-image --repository-name ${repo} \\"
        echo "         --image-ids imageTag=${src_tag} --region ${region} \\"
        echo "         --query 'images[0].imageManifest' --output text)"
        echo "       aws ecr put-image --repository-name ${repo} --image-tag ${tag} \\"
        echo "         --region ${region} --image-manifest \"\$MANIFEST\""
      else
        echo "       (no existing image to re-tag — use option B or C)"
      fi
      echo
      echo "  B) Copy from another registry (SOURCE_IMAGE=<registry>/${repo}:<tag>):"
      echo "       aws ecr get-login-password --region ${region} | \\"
      echo "         docker login --username AWS --password-stdin ${registry:-<account>.dkr.ecr.${region}.amazonaws.com}"
      echo "       docker pull \"\$SOURCE_IMAGE\""
      echo "       docker tag  \"\$SOURCE_IMAGE\" ${registry:-<registry>}/${repo}:${tag}"
      echo "       docker push ${registry:-<registry>}/${repo}:${tag}"
      echo
      echo "  C) Trigger a fresh build: run 'Build and Push Docker Images'"
      echo "     (workflow_dispatch on build-image.yml) in the nlm-ckn-etl repo."
      echo
    } >&2

    read -r -p "Press Enter to re-check ${repo}:${tag} (or Ctrl-C to abort)... "
  done

  echo "[deploy] Confirmed image ${repo}:${tag} exists in ECR." >&2
}
