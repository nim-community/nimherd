import std/[httpclient, json, os, strutils, base64, streams]

proc getToken*(): string =
  result = getEnv("GITHUB_TOKEN")

proc getClient*(): HttpClient =
  let c = newHttpClient()
  let t = getToken()
  doAssert t.len > 0, "GITHUB_TOKEN environment variable is not set"
  c.headers = newHttpHeaders({"Authorization": "Bearer " & t, "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "nimherd"})
  c

proc repoExists*(owner, repo: string): bool =
  let c = getClient()
  let resp = c.request("https://api.github.com/repos/" & owner & "/" & repo)
  result = resp.code.is2xx

proc fetchRepos*(owner: string): seq[JsonNode] =
  ## fetch all repositories of the given owner
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
  
  result = fetchPages("https://api.github.com/orgs/" & owner & "/repos?per_page=100")

proc ensureFork*(srcOwner, repo, destOrg: string): bool =
  if repoExists(destOrg, repo):
    return true
  let c = getClient()
  let payload = %*{"organization": destOrg}
  let resp = c.request("https://api.github.com/repos/" & srcOwner & "/" & repo & "/forks", httpMethod=HttpPost, body = $payload)
  if not resp.code.is2xx:
    echo "Fork request failed with status " & $resp.code
    if resp.bodyStream != nil:
      var eb = ""
      while not resp.bodyStream.atEnd:
        eb.add(readStr(resp.bodyStream, 1024))
      if eb.len > 0:
        echo eb
  for _ in 0..9:
    if repoExists(destOrg, repo):
      return true
    sleep(1000)
  false

proc syncFork*(owner, repo: string, branch = "main"): bool =
  ## sync a fork with its upstream repository
  let c = getClient()
  let url = "https://api.github.com/repos/" & owner & "/" & repo & "/merge-upstream"
  let payload = %*{"branch": branch}
  let resp = c.request(url, httpMethod=HttpPost, body = $payload)
  result = resp.code.is2xx
  if not result:
    echo "Failed to sync fork " & owner & "/" & repo & ": " & $resp.code
    if resp.bodyStream != nil:
      var s = ""
      while not resp.bodyStream.atEnd:
        s.add(readStr(resp.bodyStream, 1024))
      if s.len > 0:
        echo s

proc createPr*(org, repo, head, base, title, body: string): bool =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/pulls"
  let payload = %*{"title": title, "head": head, "base": base, "body": body}
  let resp = c.request(url, httpMethod=HttpPost, body = $payload)
  if resp.code.is2xx:
    if resp.bodyStream != nil:
      var s = ""
      while not resp.bodyStream.atEnd:
        s.add(readStr(resp.bodyStream, 1024))
      if s.len > 0:
        let j = parseJson(s)
        if j.kind == JObject and j.hasKey("html_url"):
          echo j["html_url"].getStr
    result = true
  else:
    echo "PR creation failed with status " & $resp.code
    if resp.bodyStream != nil:
      var s = ""
      while not resp.bodyStream.atEnd:
        s.add(readStr(resp.bodyStream, 1024))
      if s.len > 0:
        echo s
    result = false

proc getRef*(org, repo, refName: string): JsonNode =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/git/ref/" & refName
  let resp = c.request(url)
  if resp.code.is2xx:
    if resp.bodyStream != nil:
      var s = ""
      while not resp.bodyStream.atEnd:
        s.add(readStr(resp.bodyStream, 1024))
      if s.len > 0:
        result = parseJson(s)

proc branchExists*(org, repo, branchName: string): bool =
  let refName = "heads/" & branchName
  let branchRef = getRef(org, repo, refName)
  result = not branchRef.isNil and branchRef.kind == JObject and branchRef.hasKey("object")

proc createRef*(org, repo, refName, sha: string): bool =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/git/refs"
  let payload = %*{"ref": refName, "sha": sha}
  let resp = c.request(url, httpMethod=HttpPost, body = $payload)
  result = resp.code.is2xx
  if not result:
    echo "Failed to create ref " & refName & ": " & $resp.code

proc updateRef*(org, repo, refName, sha: string, force = false): bool =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/git/refs/" & refName
  let payload = %*{"sha": sha, "force": force}
  let resp = c.request(url, httpMethod=HttpPost, body = $payload)
  result = resp.code.is2xx
  if not result:
    echo "Failed to update ref " & refName & ": " & $resp.code

proc getFileContents*(org, repo, path: string, refName = "main"): (string, string) =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/contents/" & path & "?ref=" & refName
  let resp = c.request(url)
  if resp.code.is2xx:
    if resp.bodyStream != nil:
      var s = ""
      while not resp.bodyStream.atEnd:
        s.add(readStr(resp.bodyStream, 1024))
      if s.len > 0:
        let j = parseJson(s)
        if j.hasKey("content") and j.hasKey("sha"):
          let content = j["content"].getStr.replace("\n", "").decode()
          let sha = j["sha"].getStr
          return (content, sha)
  return ("", "")

proc updateFileContents*(org, repo, path, message, content, sha, branch: string): bool =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/contents/" & path
  let payload = %*{"message": message, "content": content.encode(), "sha": sha, "branch": branch}
  let resp = c.request(url, httpMethod=HttpPut, body = $payload)
  result = resp.code.is2xx
  if not result:
    echo "Failed to update file " & path & ": " & $resp.code

proc createFileContents*(org, repo, path, message, content, branch: string): bool =
  let c = getClient()
  let url = "https://api.github.com/repos/" & org & "/" & repo & "/contents/" & path
  let payload = %*{"message": message, "content": content.encode(), "branch": branch}
  let resp = c.request(url, httpMethod=HttpPut, body = $payload)
  result = resp.code.is2xx
  if not result:
    echo "Failed to create file " & path & ": " & $resp.code