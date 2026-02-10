# NimHerd 🐑

A tool for managing and migrating Nim packages to community ownership.

## Overview

NimHerd is like a digital shepherd for Nim packages - it helps gather and migrate packages to community ownership under the `nim-community` organization. This tool automates the process of forking repositories, updating package registry URLs, and creating pull requests to ensure packages point to their new community-maintained homes.

## Features

- **Repository Management**: Fetch and manage repositories under the `nim-community` organization
- **Automated Forking**: Automatically fork repositories that don't exist in the destination organization
- **Package Registry Updates**: Update package URLs in the Nim package registry to point to community-owned repositories
- **Pull Request Automation**: Create pull requests with the updated package information
- **Dry Run Mode**: Preview changes without making actual modifications

## Installation

```bash
nimble install nimherd
```

Or build from source:

```bash
git clone https://github.com/bung87/nimherd
cd nimherd
nimble build
```

## Usage

### Prerequisites

You'll need a GitHub personal access token with appropriate permissions. Set it as an environment variable:

```bash
export GITHUB_TOKEN=your_github_token_here
```

### Commands

#### List Repositories
```bash
nimherd list [output_file]
```
Lists all repositories in the nim-community organization. Optionally saves to a file.

#### Dry Run
```bash
nimherd dry-run [work_directory]
```
Performs a dry run to show what changes would be made without actually executing them.

#### Run Migration
```bash
nimherd run [work_directory] [--only=package1,package2]
```
Executes the full migration process:
1. Forks repositories to nim-community organization if needed
2. Updates package registry URLs
3. Creates pull requests with the changes

Use `--only` to process specific packages.

#### Create Pull Requests
```bash
nimherd makePrs [work_directory]
```
Creates pull requests for packages that have been updated in the working directory.

## How It Works

1. **Repository Discovery**: Fetches all repositories from the `nim-community` GitHub organization
2. **Package Analysis**: Downloads the current Nim package registry and analyzes each package
3. **URL Updates**: For packages that exist in nim-community, updates their URLs to point to the community-owned repositories
4. **Pull Request Creation**: Creates pull requests to the main Nim packages repository with the updated information

## Configuration

The tool uses these constants (defined in the source):
- `Org`: The target organization (default: "nim-community")
- Various GitHub API endpoints for repository management

## API Reference

### Key Procedures

- `fetchRepos*()`: Fetch repositories from nim-community organization
- `ensureFork(srcOwner, repo, destOrg)`: Ensure a repository exists as a fork
- `updateUrls(nimblePath, newUrl)`: Update URLs in .nimble files
- `createPr(owner, repo, head, base, title, body)`: Create pull requests

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - see the LICENSE file for details.
# nimherd
