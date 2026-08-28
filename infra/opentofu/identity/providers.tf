# No `cluster` default tag, unlike `prod/` and `test/`: these resources belong
# to neither cluster. Tagging them `cluster = prod` — which is what they
# inherited while they lived in the prod root module — would put the deployer
# roles inside the reach of the test-infra boundary's `cluster=prod` deny, which
# reads as if it were protecting them but is really about production
# infrastructure. `layer = identity` says what they are instead.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project   = "alchemiscale"
      managedby = "opentofu"
      layer     = "identity"
    }
  }
}
