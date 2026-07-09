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
