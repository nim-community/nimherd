
import std/[httpclient, json, strutils, os, osproc, uri, sequtils, streams, tables]
import diff
import dotenv
import cligen

const Org = "nim-community"

proc shellQuote(s: string): string =
  "\"" & s.replace("\"", "\\\"") & "\""

proc runCmd(args: seq[string], cwd = ""): (int, string) =
  var cmd = args.mapIt(shellQuote(it)).join(" ")
  if cwd.len > 0:
    cmd = "cd " & shellQuote(cwd) & " && " & cmd
  let res = execCmdEx(cmd)
  return (res.exitCode, res.output)

proc getToken(): string =
  result = getEnv("GITHUB_TOKEN")

proc getClient(): HttpClient =
  let c = newHttpClient()
  let t = getToken()
  if t.len > 0:
    c.headers = newHttpHeaders({"Authorization": "Bearer " & t, "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "nimherd"})
  else:
    c.headers = newHttpHeaders({"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "nimherd"})
  c

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

proc repoExists(owner, repo: string): bool =
  let c = getClient()
  let resp = c.request("https://api.github.com/repos/" & owner & "/" & repo)
  result = resp.code.is2xx

proc ensureFork(srcOwner, repo, destOrg: string): bool =
  if repoExists(destOrg, repo):
    return true
  let c = getClient()
  let payload = %*{"organization": destOrg}
  let resp = c.request("https://api.github.com/repos/" & srcOwner & "/" & repo & "/forks", httpMethod=HttpPost, body = $payload)
  if not resp.code.is2xx:
    echo "Fork request failed with status " & $resp.code
    let bs = resp.bodyStream
    if bs != nil:
      let eb = bs.readAll()
      if eb.len > 0:
        echo eb
  for _ in 0..9:
    if repoExists(destOrg, repo):
      return true
    sleep(1000)
  false


proc fetchRepos*(): JsonNode =
  let c = getClient()
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
  var items = fetchPages("https://api.github.com/orgs/" & Org & "/repos?per_page=100")
  if items.len == 0:
    let url = "https://api.github.com/search/repositories?q=user:" & Org & "&per_page=100"
    let body = c.getContent(url)
    let j = parseJson(body)
    if j.hasKey("items") and j["items"].kind == JArray:
      var arr: seq[JsonNode] = @[]
      for it in j["items"]:
        arr.add it
      return %arr
  if items.len == 0:
    let url = "https://api.github.com/orgs/" & Org & "/repos?per_page=100"
    let body = c.getContent(url)
    let j = parseJson(body)
    if j.kind == JArray:
      var arr: seq[JsonNode] = @[]
      for it in j:
        arr.add it
      return %arr
  %items



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

proc createPr(org, repo, head, base, title, body: string): bool =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/pulls"
  let payload = %*{"title": title, "head": head, "base": base, "body": body}
  let resp = c.request(url, httpMethod=HttpPost, body = $payload)
  if resp.code.is2xx:
    let bs = resp.bodyStream
    if bs != nil:
      let s = bs.readAll()
      if s.len > 0:
        let j = parseJson(s)
        if j.kind == JObject and j.hasKey("html_url"):
          echo j["html_url"].getStr
    result = true
  else:
    echo "PR creation failed with status " & $resp.code
    let bs = resp.bodyStream
    if bs != nil:
      let s = bs.readAll()
      if s.len > 0:
        echo s
    result = false

proc makePrs(workdir: string) =
  createDir(workdir)
  let repos = fetchRepos()
  var pkgs: JsonNode = newJArray()
  let c = getClient()
  let body = c.getContent("https://cdn.jsdelivr.net/gh/nim-lang/packages@master/packages.json")
  pkgs = parseJson(body)

  var changedPkgs: seq[string] = @[]
  for i in 0 ..< pkgs.len:
    let name = pkgs[i]["name"].getStr
    var html = ""
    for r in repos:
      if r["name"].getStr == name:
        html = r["html_url"].getStr
        break
    if html.len == 0:
      continue
    let oldUrl = if pkgs[i].hasKey("url"): pkgs[i]["url"].getStr else: ""
    let oldWeb = if pkgs[i].hasKey("web"): pkgs[i]["web"].getStr else: ""
    var didChange = false
    if oldUrl != html:
      pkgs[i]["url"] = %html
      didChange = true
    if oldWeb != html:
      pkgs[i]["web"] = %html
      didChange = true
    if didChange:
      changedPkgs.add name
  let repoDir = workdir / "packages"
  discard runCmd(@["rm", "-rf", repoDir])
  var cloneUrl = "https://github.com/" & Org & "/packages.git"
  let token = getToken()
  if token.len > 0:
    if not ensureFork("nim-lang", "packages", Org):
      echo "Failed to fork nim-lang/packages for org '" & Org & "'"
      quit(1)
    cloneUrl = "https://x-access-token:" & token & "@github.com/" & Org & "/packages.git"
  let (gc, gout) = runCmd(@["git", "clone", cloneUrl, repoDir])
  if gc != 0:
    echo "git clone failed with exit code " & $gc
    if gout.len > 0:
      echo gout
    quit(1)
  let pkgPath = repoDir / "packages.json"
  writeFile(pkgPath, $pkgs)
  let branch = "update-nim-community-urls"
  if token.len > 0:
    discard runCmd(@["git", "remote", "set-url", "origin", cloneUrl], repoDir)
  discard runCmd(@["git", "checkout", "master"], repoDir)
  discard runCmd(@["git", "checkout", "-b", branch], repoDir)
  discard runCmd(@["git", "add", pkgPath], repoDir)
  let (cc, cout) = runCmd(@["git", "commit", "-m", "Update registry URLs to nim-community repos"], repoDir)
  if cc == 0:
    let (pc, pout) = runCmd(@["git", "push", "-u", "origin", branch], repoDir)
    if pc == 0:
      let names = changedPkgs.join(", ")
      let prTitle = if names.len > 0: "Update registry URLs for " & names else: "Update registry URLs to nim-community repos"
      let prBody = if names.len > 0: "Set url/web to nim-community-owned repositories for: " & names else: "Set url/web to nim-community-owned repositories where applicable"
      let headRef = Org & ":" & branch
      discard createPr("nim-lang", "packages", headRef, "master", prTitle, prBody)
    else:
      echo "git push failed with exit code " & $pc
      if pout.len > 0:
        echo pout
      if pout.contains("non-fast-forward"):
        discard runCmd(@["git", "pull", "--rebase", "origin", branch], repoDir)
        let (pc2, pout2) = runCmd(@["git", "push", "--force-with-lease", "-u", "origin", branch], repoDir)
        if pc2 == 0:
          let names = changedPkgs.join(", ")
          let prTitle = if names.len > 0: "Update registry URLs for " & names else: "Update registry URLs to nim-community repos"
          let prBody = if names.len > 0: "Set url/web to nim-community-owned repositories for: " & names else: "Set url/web to nim-community-owned repositories where applicable"
          let headRef = Org & ":" & branch
          discard createPr("nim-lang", "packages", headRef, "master", prTitle, prBody)
        else:
          if pout2.len > 0:
            echo pout2
  else:
    echo "No changes to commit (" & $changedPkgs.len & " packages updated in memory)"
    if cout.len > 0:
      echo cout

proc outputList() =
  let repos = fetchRepos()
  var filteredRepos = newJArray()
  for repo in repos:
    if repo.hasKey("name") and repo.hasKey("html_url"):
      var filteredRepo = newJObject()
      filteredRepo["name"] = repo["name"]
      filteredRepo["html_url"] = repo["html_url"]
      filteredRepos.add(filteredRepo)
  echo pretty filteredRepos


proc dryRun(path: string) =
  let repos = fetchRepos()
  var pkgs: JsonNode = newJArray()
  let c = getClient()
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
  writeFile(origPath, pkgs.pretty)
  writeFile(newPath, pkgsNew.pretty)
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
