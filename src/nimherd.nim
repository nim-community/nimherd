
import std/[httpclient, json, strutils, os, osproc, sequtils, tables, times]
import diff
import dotenv
import cligen
import simpledb
import nimherd/[githubapi,pretty_json]

var db: SimpleDB

proc initDatabase(): SimpleDB =
  result = SimpleDB.init("packages.db")

proc storePackagesInDb(packages: JsonNode) =
  if db.isNil:
    db = initDatabase()
  
  # Clear existing packages
  db.query().where("type", "==", "package").remove()
  
  # Store each package as a document
  for i in 0 ..< packages.len:
    let pkg = packages[i]
    if pkg.hasKey("name"):
      var doc = pkg.copy() # avoid mutating original
      doc["type"] = %"package"
      doc["stored_at"] = %getTime().toUnix
      db.put(doc)

proc getChangedPackagesFromDb(repos: seq[JsonNode]): seq[string] =
  if db.isNil:
    db = initDatabase()
  
  result = @[]
  for repo in repos:
    let repoName = repo["name"].getStr
    let repoUrl = repo["html_url"].getStr
    
    # Query for existing package with this name
    let existing = db.query().where("name", "==", repoName).where("type", "==", "package").get()
    
    if existing.isNil:
      # New package
      result.add(repoName)
    else:
      # Check if URL changed
      let oldUrl = if existing.hasKey("url"): existing["url"].getStr else: ""
      let oldWeb = if existing.hasKey("web"): existing["web"].getStr else: ""
      if oldUrl != repoUrl or oldWeb != repoUrl:
        result.add(repoName)

const Org = "nim-community"

proc shellQuote(s: string): string =
  "\"" & s.replace("\"", "\\\"") & "\""

proc runCmd(args: seq[string], cwd = ""): (int, string) =
  var cmd = args.mapIt(shellQuote(it)).join(" ")
  if cwd.len > 0:
    cmd = "cd " & shellQuote(cwd) & " && " & cmd
  let res = execCmdEx(cmd)
  return (res.exitCode, res.output)


proc nimbleCandidates(repoName: string): seq[string] =
  var cands: seq[string] = @[]
  let base = repoName
  let lower = base.toLowerAscii
  let stripped = if lower.endsWith(".nim"): lower[0..lower.len-5] else: lower
  let altPrefix = if stripped.startsWith("nim-"): stripped[4..^1] else: stripped
  let altSuffix = if stripped.endsWith("-nim"): stripped[0..stripped.len-5] else: stripped
  proc addVariant(s: string) =
    if s.len > 0:
      cands.add s
      cands.add s.replace("-", "_")
      cands.add s.replace("_", "-")
  addVariant(lower)
  addVariant(stripped)
  addVariant(altPrefix)
  addVariant(altSuffix)
  result = @[]
  for s in cands:
    if not (s in result):
      result.add s


proc fetchRepos*(): seq[JsonNode] =
  let c = githubapi.getClient()
  proc fetchPages(urlPrefix: string): seq[JsonNode] =
    var page = 1
    var items: seq[JsonNode] = @[]
    while true:
      let url = urlPrefix & "&page=" & $page
      let body = c.getContent(url)
      let j = parseJson(body)
      if j.kind != JArray:
        break
      if j.len == 0:
        break
      for r in j:
        items.add r
      inc page
    items
  
  result = fetchPages("https://api.github.com/orgs/" & Org & "/repos?per_page=100")
  echo "Fetched " & $result.len & " repositories"


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
  let repos = fetchRepos()

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
      let name = url.split("/")[^1]  # Get last part of URL
      if name in changedPkgs:
        var html = ""
        for r in repos:
          if r["name"].getStr == name:
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
  let repos = fetchRepos()
  var filteredRepos = newJArray()
  for repo in repos:
    if repo.hasKey("name") and repo.hasKey("html_url"):
      var filteredRepo = newJObject()
      filteredRepo["name"] = repo["name"]
      filteredRepo["html_url"] = repo["html_url"]
      filteredRepos.add(filteredRepo)
  echo  filteredRepos.pretty.cleanupWhitespace


proc dryRun() =
  let repos = fetchRepos()
  var pkgs: JsonNode = newJArray()
  let c = githubapi.getClient()
  let body = c.getContent("https://cdn.jsdelivr.net/gh/nim-lang/packages@master/packages.json")
  pkgs = parseJson(body)


  var pkgsNew = pkgs.copy()
  for r in repos:
    let name = r["name"].getStr
    let html = r["html_url"].getStr
    var idx = -1
    for i in 0 ..< pkgsNew.len:
      if pkgsNew[i].hasKey("name") and pkgsNew[i]["name"].getStr == name:
        idx = i
        break
    if idx < 0:
      for cand in nimbleCandidates(name):
        for i in 0 ..< pkgsNew.len:
          if pkgsNew[i].hasKey("name") and pkgsNew[i]["name"].getStr == cand:
            idx = i
            break
        if idx >= 0:
          break
    if idx < 0:
      let suf1 = "/" & name
      let strippedName = if name.endsWith(".nim"): name[0..name.len-5] else: name
      let suf2 = "/" & strippedName
      for i in 0 ..< pkgsNew.len:
        var matched = false
        if pkgsNew[i].hasKey("url"):
          let u = pkgsNew[i]["url"].getStr
          if u.endsWith(suf1) or u.endsWith(suf2):
            matched = true
        if not matched and pkgsNew[i].hasKey("web"):
          let w = pkgsNew[i]["web"].getStr
          if w.endsWith(suf1) or w.endsWith(suf2):
            matched = true
        if matched:
          idx = i
          break
    if idx >= 0:
      if not pkgsNew[idx].hasKey("url") or pkgsNew[idx]["url"].getStr != html:
        pkgsNew[idx]["url"] = %html
      if not pkgsNew[idx].hasKey("web") or pkgsNew[idx]["web"].getStr != html:
        pkgsNew[idx]["web"] = %html

  let tmp = getTempDir() / "nim_packages_dry_run_json"
  discard runCmd(@["rm", "-rf", tmp])
  createDir(tmp)
  let origPath = tmp / "packages_orig.json"
  let newPath = tmp / "packages_new.json"
  writeFile(origPath, pkgs.pretty.cleanupWhitespace)
  writeFile(newPath, pkgsNew.pretty.cleanupWhitespace)
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
