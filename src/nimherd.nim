
import std/[httpclient, json, strutils, os, tables]
import diff
import dotenv
import cligen
import simpledb
import nimherd/[githubapi,pretty_json]

const Org = "nim-community"


var db: SimpleDB

proc initDatabase(): SimpleDB =
  result = SimpleDB.init("packages.db")

proc storePackagesInDb(packages: JsonNode) =
  if db.isNil:
    db = initDatabase()
  defer: db.close()
  # Clear existing packages
  db.query().remove()
  
  # Store each package as a document
  for i in 0 ..< packages.len:
    let pkg = packages[i]
    if pkg.hasKey("name"):
      var doc = pkg.copy() # avoid mutating original

      db.put(doc)

proc getChangedPackagesFromDb(forkedRepos: seq[JsonNode]): seq[string] =
  ## Returns a list of package names that have changed URLs in the database.
  if db.isNil:
    db = initDatabase()
  defer: db.close()
  for forkedRepo in forkedRepos:
    let repoName = forkedRepo["name"].getStr
    let pkgName = repoName.split(".")[0]
    let repoUrl = forkedRepo["html_url"].getStr
    
    # Query for existing package with this name
    let orig = db.query().where("name", "==", pkgName).get()

    if orig.isNil:
      # forked repos that not in nim official packages.json
      discard
    else:
      # Check if URL changed
      let oldUrl = if orig.hasKey("url"): orig["url"].getStr else: ""
      let oldWeb = if orig.hasKey("web"): orig["web"].getStr else: ""
      if oldUrl != repoUrl or oldWeb != repoUrl:
        result.add(pkgName)


proc updateUrls*(nimblePath: string, newUrl: string): bool =
  var changed = false
  if not fileExists(nimblePath):
    return false
  var lines = readFile(nimblePath).splitLines()
  for i in 0 ..< lines.len:
    let line = lines[i]
    if line.contains("homepage") and line.contains("="):
      let p = line.find('"')
      if p >= 0:
        let q = line.find('"', p+1)
        if q > p:
          let cur = line[p+1..q-1]
          if cur != newUrl:
            lines[i] = line[0..p] & newUrl & line[q..^1]
            changed = true
    elif line.contains("url") and line.contains("=") and line.strip.startsWith("url"):
      let p = line.find('"')
      if p >= 0:
        let q = line.find('"', p+1)
        if q > p:
          let cur = line[p+1..q-1]
          if cur != newUrl:
            lines[i] = line[0..p] & newUrl & line[q..^1]
            changed = true
  if not changed:
    lines.add("homepage        = \"" & newUrl & "\"")
    changed = true
  if changed:
    writeFile(nimblePath, lines.join("\n"))
  changed


proc makePrs(workdir: string) =
  createDir(workdir)
  let repos = fetchRepos(Org)

  var pkgs: JsonNode = newJArray()
  let c = githubapi.getClient()
  let body = c.getContent("https://cdn.jsdelivr.net/gh/nim-lang/packages@master/packages.json")
  pkgs = parseJson(body)
  
  # Store packages in SimpleDB
  storePackagesInDb(pkgs)
  
  # Get changed packages using SimpleDB query
  let changedPkgs = getChangedPackagesFromDb(repos)

  if changedPkgs.len == 0:
    echo "No packages to update"
    return

  # Update the packages JSON with new URLs
  for i in 0 ..< pkgs.len:

    if "url" in pkgs[i]:
      let url = pkgs[i]["url"].getStr
      let repoName = url.split("/")[^1]  # Get last part of URL
      let pkgName = repoName.split(".")[0]
      if pkgName in changedPkgs:
        var html = ""
        for r in repos:
          if r["name"].getStr.split(".")[0] == pkgName:
            html = r["html_url"].getStr
            break
        if html.len > 0:
          pkgs[i]["url"] = %html
          pkgs[i]["web"] = %html
  # Use GitHub API to create/update the packages.json file
  let branch = "update-nim-community-urls-" & changedPkgs.join("-")
  let message = "Update registry URLs to nim-community repos"
  
  # Ensure fork exists
  if not githubapi.ensureFork("nim-lang", "packages", Org):
    echo "Failed to fork nim-lang/packages for org '" & Org & "'"
    quit(1)
  
  # Get current master branch SHA
  let masterRef = githubapi.getRef(Org, "packages", "heads/master")
  if masterRef.isNil:
    echo "Failed to get master branch reference"
    quit(1)
  
  let masterSha = masterRef["object"]["sha"].getStr

  # Create new branch
  let branchRef = "refs/heads/" & branch
  
  # Check if branch already exists
  if githubapi.branchExists(Org, "packages", branch):
    echo "Branch " & branch & " already exists, skipping creation"
  else:
    if not githubapi.createRef(Org, "packages", branchRef, masterSha):
      echo "Failed to create branch " & branch
      quit(1)
  
  # Get current packages.json file
  let (currentContent, fileSha) = githubapi.getFileContents(Org, "packages", "packages.json", "master")
  writeFile(workdir / "packages.json", currentContent)
  # Update packages.json
  let updatedContent = pkgs.pretty.cleanupWhitespace
  writeFile(workdir / "updated-packages.json", updatedContent)
  var success = false
  if currentContent.len > 0:
    if currentContent != updatedContent:
      success = githubapi.updateFileContents(Org, "packages", "packages.json", message, updatedContent, fileSha, branch)
      if not success:
        echo "Failed to update packages.json"
        quit(1)
    else:
      discard
  else:
    success = githubapi.createFileContents(Org, "packages", "packages.json", message, updatedContent, branch)
    if not success:
      echo "Failed to create packages.json"
      quit(1)
  
  
  # Create PR
  let names = changedPkgs.join(", ")
  let prTitle = "Update registry URLs for " & names
  let prBody = "Set url/web to nim-community-owned repositories for: " & names
  let headRef = Org & ":" & branch
  discard githubapi.createPr("nim-lang", "packages", headRef, "master", prTitle, prBody)

proc outputList() =
  ## list nim-community repositories
  let repos = fetchRepos(Org)
  var filteredRepos = newJArray()
  for repo in repos:
    if repo.hasKey("name") and repo.hasKey("html_url"):
      var filteredRepo = newJObject()
      filteredRepo["name"] = repo["name"]
      filteredRepo["html_url"] = repo["html_url"]
      filteredRepos.add(filteredRepo)
  echo  filteredRepos.pretty.cleanupWhitespace


proc dryRun() =
  let repos = fetchRepos(Org)
  var pkgs: JsonNode = newJArray()
  let c = githubapi.getClient()
  let body = c.getContent("https://cdn.jsdelivr.net/gh/nim-lang/packages@master/packages.json")
  pkgs = parseJson(body)
  let original = pkgs.pretty.cleanupWhitespace
  # Store packages in SimpleDB
  storePackagesInDb(pkgs)
  
  # Get changed packages using SimpleDB query
  let changedPkgs = getChangedPackagesFromDb(repos)

  # Update the packages JSON with new URLs
  for i in 0 ..< pkgs.len:

    if "url" in pkgs[i]:
      let url = pkgs[i]["url"].getStr
      let repoName = url.split("/")[^1]  # Get last part of URL
      let pkgName = repoName.split(".")[0]
      if pkgName in changedPkgs:
        var html = ""
        for r in repos:
          if r["name"].getStr.split(".")[0] == pkgName:
            html = r["html_url"].getStr
            break
        if html.len > 0:
          pkgs[i]["url"] = %html
          pkgs[i]["web"] = %html

  let tmp = getTempDir() / "nim_packages_dry_run_json"
  removeDir(tmp)
  createDir(tmp)
  let origPath = tmp / "packages_orig.json"
  let newPath = tmp / "packages_new.json"
  writeFile(origPath, original)
  writeFile(newPath, pkgs.pretty.cleanupWhitespace)
  let a = readFile(origPath).splitLines()
  let b = readFile(newPath).splitLines()
  var any = false
  for span in spanSlices(a, b):
    case span.tag
    of tagReplace:
      for t in span.a:
        echo "- ", t
        any = true
      for t in span.b:
        echo "+ ", t
        any = true
    of tagDelete:
      for t in span.a:
        echo "- ", t
        any = true
    of tagInsert:
      for t in span.b:
        echo "+ ", t
        any = true
    of tagEqual:
      discard
  if not any:
    echo "No differences in packages.json"


proc run(workdir = getCurrentDir() / "_work_nim_community") =
  createDir(workdir)
  makePrs(workdir)

when isMainModule:
  dotenv.load()
  dispatchMulti(
    [outputList, cmdName = "list"],
    [run, cmdName = "run"],
    [dryRun, cmdName = "dry-run"],
    [makePrs, cmdName = "makePrs"]
  )
