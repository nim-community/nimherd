# Package

version       = "0.1.0"
author        = "bung87"
description   = "A tool for managing and migrating Nim packages to community ownership"
license       = "MIT"
srcDir        = "src"
bin           = @["nimherd"]


# Dependencies

# requires "nim >= 2.0.0"
requires "dotenv"
requires "cligen"
requires "diff"
