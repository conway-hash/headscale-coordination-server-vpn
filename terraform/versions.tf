terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.44"
    }
  }

  # Bucket and prefix are intentionally NOT hardcoded here — they're supplied
  # at `tofu init` time via -backend-config so this repo stays project-agnostic
  # and never bakes in a project-specific bucket name. See SETUP.md.
  backend "gcs" {}
}
