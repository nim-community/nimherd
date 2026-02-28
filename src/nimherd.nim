
import std/[httpclient, json, strutils, os, tables, times, uri, math, httpcore, algorithm, sets]
import dotenv
import cligen
import simpledb,diff
import db_connector/db_sqlite
import nimherd/[githubapi,pretty_json]

const Org = "nim-community"

proc initDatabase(): SimpleDB =
  result = SimpleDB.init("packages.db")

proc storePackagesInDb(db: SimpleDB, packages: JsonNode) =
  # Store each package as a document using batch transaction
  db.batch do():
    for pkg in packages:
      if pkg.hasKey("name"):
        db.put(pkg)

proc getChangedPackagesFromDb(db: SimpleDB, forkedRepos: seq[JsonNode]): seq[string] =
  ## Returns a list of package names that have changed URLs in the database.
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
        result.add(repoName)


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


proc makePrs() =

  let repos = fetchRepos(Org)
  var pkgs: JsonNode = newJArray()
  let c = githubapi.getClient()
  let body = c.getContent("https://cdn.jsdelivr.net/gh/nim-lang/packages@master/packages.json")
  pkgs = parseJson(body)

  # Create database connection
  let db = initDatabase()
  defer: db.close()

  # Store packages in SimpleDB
  storePackagesInDb(db, pkgs.copy)

  # Get changed packages using SimpleDB query
  let changedPkgs = getChangedPackagesFromDb(db, repos)

  if changedPkgs.len == 0:
    echo "No packages to update"
    return
  else:
    echo "Changed packages: " & changedPkgs.join(", ")
  # Update the packages JSON with new URLs
  for i in 0 ..< pkgs.len:
    if "url" in pkgs[i]:
      let url = pkgs[i]["url"].getStr.strip(chars={'/'})
      let repoName = url.split("/")[^1]  # Get last part of URL
      # let pkgName = repoName.split(".")[0]

      if repoName in changedPkgs:
        var html = ""
        for r in repos:
          if r["name"].getStr == repoName:
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

  # Update packages.json
  let updatedContent = pkgs.pretty.cleanupWhitespace

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

  # Create database connection
  let db = initDatabase()
  defer: db.close()

  # Store packages in SimpleDB
  storePackagesInDb(db, pkgs.copy)

  # Get changed packages using SimpleDB query
  let changedPkgs = getChangedPackagesFromDb(db, repos)
  echo "Changed packages: " & changedPkgs.join(", ")
  # Update the packages JSON with new URLs
  for i in 0 ..< pkgs.len:
    if "url" in pkgs[i]:
      let url = pkgs[i]["url"].getStr.strip(chars={'/'})
      let repoName = url.split("/")[^1]  # Get last part of URL
      # let pkgName = repoName.split(".")[0]
      if repoName in changedPkgs:
        var html = ""
        for r in repos:
          if r["url"].getStr.split("/")[^1] == repoName:
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


proc run() =
  removeFile("packages.db")
  discard syncFork("nim-community", "packages", "master")
  makePrs()

proc isStale(lastAccess: DateTime): bool =
  ## Check if package was accessed within last 24 hours
  let now = now()
  let diff = now - lastAccess
  result = diff.inHours >= 24

proc initHealthDatabase(): DbConn =
  ## Initialize separate SQLite database for package health data
  result = open("packages_health.db", "", "", "")
  # Create table if not exists
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS package_health (
      name TEXT PRIMARY KEY,
      url TEXT,
      http_status INTEGER,
      last_access_time TEXT,
      access_error TEXT,
      json_data TEXT
    )
  """)
  # Create index for status queries
  result.exec(sql"CREATE INDEX IF NOT EXISTS idx_status ON package_health(http_status)")

proc getHealthCheckProgress(db: DbConn): tuple[total: int, completed: int, failed: int] =
  ## Get current progress of health checks
  result.total = 0
  result.completed = 0
  result.failed = 0
  
  let countRow = db.getRow(sql"SELECT COUNT(*), SUM(CASE WHEN http_status > 0 THEN 1 ELSE 0 END), SUM(CASE WHEN http_status = 0 THEN 1 ELSE 0 END) FROM package_health")
  if countRow[0] != "":
    result.total = parseInt(countRow[0])
    result.completed = if countRow[1] != "": parseInt(countRow[1]) else: 0
    result.failed = if countRow[2] != "": parseInt(countRow[2]) else: 0

proc checkPackageHealth*(concurrentRequests = 10, forceCheck = false) =
  ## Check health of packages by making HTTP HEAD requests to their URLs
  echo "Fetching package list from nim-lang/packages..."
  
  let c = githubapi.getClient()
  let body = c.getContent("https://cdn.jsdelivr.net/gh/nim-lang/packages@master/packages.json")
  let pkgs = parseJson(body)
  
  echo "Found ", pkgs.len, " packages to check"
  
  # Use separate database for health data
  let healthDb = initHealthDatabase()
  defer: healthDb.close()
  
  # Get current progress
  let progress = getHealthCheckProgress(healthDb)
  echo "Current progress: ", progress.completed, "/", progress.total, " completed, ", progress.failed, " failed"
  
  var packagesToCheck: seq[JsonNode] = @[]
  var skippedCount = 0
  var staleCount = 0
  
  # First pass: identify packages that need checking
  for pkg in pkgs:
    if not pkg.hasKey("name") or not pkg.hasKey("url"):
      continue
      
    let pkgName = pkg["name"].getStr
    
    # Check if package exists in health database
    let existingRow = healthDb.getRow(sql"SELECT http_status, last_access_time FROM package_health WHERE name = ?", pkgName)
    
    var shouldCheck = forceCheck
    if not shouldCheck and existingRow[0] != "":
      # Check if we have a valid health record
      let lastAccessStr = existingRow[1]
      if lastAccessStr != "":
        let lastAccess = parse(lastAccessStr, "yyyy-MM-dd'T'HH:mm:ss'Z'")
        if isStale(lastAccess):
          shouldCheck = true
          inc staleCount
        else:
          inc skippedCount
      else:
        shouldCheck = true
    elif existingRow[0] == "":
      shouldCheck = true
    
    if shouldCheck:
      packagesToCheck.add(pkg)
  
  echo "Need to check ", packagesToCheck.len, " packages (", staleCount, " stale, ", skippedCount, " skipped)"
  
  if packagesToCheck.len == 0:
    echo "All packages are up to date"
    return
  
  var results: seq[JsonNode] = @[]
  var failedPackages: seq[string] = @[]
  var deprecatedPackages: seq[string] = @[]
  
  # Process packages with synchronous HTTP requests and timeout
  proc checkSinglePackage(pkg: JsonNode): JsonNode =
    result = pkg.copy
    let pkgName = pkg["name"].getStr
    let pkgUrl = pkg["url"].getStr
    
    try:
      let client = newHttpClient(timeout = 10000) # 10 second timeout
      defer: client.close()
      
      # Parse URL and ensure it's valid
      let parsedUrl = parseUri(pkgUrl)
      if parsedUrl.scheme == "":
        result["http_status"] = %0
        result["last_access_time"] = %(format(now(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
        result["access_error"] = %"Invalid URL scheme"
        return result
      
      # Make HEAD request
      let response = client.request(pkgUrl, httpMethod = HttpHead)
      let statusCode = response.code.int
      
      result["http_status"] = %statusCode
      result["last_access_time"] = %(format(now(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
      
      # Check for deprecated packages (404, 410, etc.)
      if statusCode == 404 or statusCode == 410:
        deprecatedPackages.add(pkgName)
      elif statusCode >= 400:
        failedPackages.add(pkgName & " (" & $statusCode & ")")
        
    except CatchableError as e:
      result["http_status"] = %0
      result["last_access_time"] = %(format(now(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
      result["access_error"] = %e.msg
      failedPackages.add(pkgName & " (" & e.msg & ")")
  
  # Process packages in batches to avoid overwhelming servers
  let batchSize = min(concurrentRequests, packagesToCheck.len)
  echo "Checking packages with ", batchSize, " concurrent requests..."
  
  var processed = 0
  var newlyProcessed = 0
  for i in 0 ..< packagesToCheck.len:
    let result = checkSinglePackage(packagesToCheck[i])
    results.add(result)
    
    # Store result in health database immediately (incremental save)
    let pkgName = packagesToCheck[i]["name"].getStr
    let pkgUrl = result["url"].getStr
    let httpStatus = result["http_status"].getInt
    let lastAccess = result["last_access_time"].getStr
    let accessError = if result.hasKey("access_error"): result["access_error"].getStr else: ""
    
    # Insert or replace record in SQLite
    healthDb.exec(sql"""
      INSERT OR REPLACE INTO package_health (name, url, http_status, last_access_time, access_error, json_data)
      VALUES (?, ?, ?, ?, ?, ?)
    """, pkgName, pkgUrl, httpStatus, lastAccess, accessError, $result)
    
    inc processed
    inc newlyProcessed
    
    # Progress update every 10 packages
    if processed mod 10 == 0:
      echo "Progress: ", processed, "/", packagesToCheck.len, " (", newlyProcessed, " new)"
      
      # Show intermediate results every 50 packages
      if processed mod 50 == 0 and (deprecatedPackages.len > 0 or failedPackages.len > 0):
        echo "  Intermediate: ", deprecatedPackages.len, " deprecated, ", failedPackages.len, " failed"
  
  # Get final comprehensive results from health database
  let finalProgress = getHealthCheckProgress(healthDb)
  
  # Sample records to get accurate statistics
  var finalDeprecated: seq[string] = @[]
  var finalFailed: seq[string] = @[]
  var finalStatusCounts: Table[int, int]
  
  for row in healthDb.rows(sql"SELECT name, http_status FROM package_health LIMIT 2000"):
    let pkgName = row[0]
    let status = parseInt(row[1])
    
    if not finalStatusCounts.hasKey(status):
      finalStatusCounts[status] = 0
    finalStatusCounts[status] = finalStatusCounts[status] + 1
    
    if status == 404 or status == 410:
      finalDeprecated.add(pkgName)
    elif status >= 400:
      finalFailed.add(pkgName & " (" & $status & ")")
  
  echo "\n=== Package Health Check Results ==="
  echo "Total packages in database: ", finalProgress.total
  echo "Successfully checked: ", finalProgress.completed
  echo "Failed checks: ", finalProgress.failed
  echo "Newly processed this run: ", newlyProcessed
  
  if finalDeprecated.len > 0:
    echo "\nPotentially deprecated packages (404/410):"
    for pkg in finalDeprecated:
      echo "  - ", pkg
  
  if finalFailed.len > 0:
    echo "\nFailed packages (other errors):"
    for pkg in finalFailed:
      echo "  - ", pkg
  
  echo "\nHTTP Status Summary:"
  for status, count in finalStatusCounts:
    echo "  ", status, ": ", count

proc printHealthStatus*(filter: string = "all", limit: int = 100, sortBy: string = "name") =
  ## Print package health status from the database
  echo "Loading package health data from database..."
  
  let healthDb = initHealthDatabase()
  defer: healthDb.close()
  
  # Get health records based on filter using SQLite queries
  var healthRecords: seq[JsonNode] = @[]
  var sqlQuery: SqlQuery
  
  case filter.toLower():
  of "all":
    sqlQuery = sql"SELECT json_data FROM package_health ORDER BY name LIMIT ?"
    for row in healthDb.rows(sqlQuery, limit):
      healthRecords.add(parseJson(row[0]))
  of "deprecated", "dead":
    sqlQuery = sql"SELECT json_data FROM package_health WHERE http_status IN (404, 410) ORDER BY name LIMIT ?"
    for row in healthDb.rows(sqlQuery, limit):
      healthRecords.add(parseJson(row[0]))
  of "failed", "errors":
    # Get packages with status 0 or >= 400 (excluding 404/410)
    sqlQuery = sql"""
      SELECT json_data FROM package_health 
      WHERE http_status = 0 OR (http_status >= 400 AND http_status NOT IN (404, 410))
      ORDER BY name LIMIT ?
    """
    for row in healthDb.rows(sqlQuery, limit):
      healthRecords.add(parseJson(row[0]))
  of "success", "ok":
    # Get packages with successful status (200-399)
    sqlQuery = sql"SELECT json_data FROM package_health WHERE http_status BETWEEN 200 AND 399 ORDER BY name LIMIT ?"
    for row in healthDb.rows(sqlQuery, limit):
      healthRecords.add(parseJson(row[0]))
  else:
    echo "Unknown filter: ", filter
    echo "Available filters: all, deprecated, failed, success"
    return
  
  if healthRecords.len == 0:
    echo "No health records found in database. Run 'check-pkg-health' first to populate the database."
    return
  
  echo "Found ", healthRecords.len, " packages with filter: ", filter
  
  # Sort records using system sort
  case sortBy.toLower():
  of "name":
    healthRecords.sort(proc(a, b: JsonNode): int =
      cmp(a["name"].getStr, b["name"].getStr))
  of "status", "http_status":
    healthRecords.sort(proc(a, b: JsonNode): int =
      cmp(a["http_status"].getInt, b["http_status"].getInt))
  of "time", "last_access":
    healthRecords.sort(proc(a, b: JsonNode): int =
      cmp(a["last_access_time"].getStr, b["last_access_time"].getStr))
  
  # When using a filter (not "all"), just print name and URL
  if filter.toLower() != "all":
    for record in healthRecords:
      if not record.hasKey("name") or not record.hasKey("url"):
        continue
      let pkgName = record["name"].getStr
      let pkgUrl = record["url"].getStr
      echo pkgName, " ", pkgUrl
    return
  
  # Print header for "all" filter
  echo "\n=== Package Health Status ==="
  echo "Name                          | Status | Last Access         "
  echo "----------------------------------------------------------"
  
  # Print records
  var deprecatedCount = 0
  var failedCount = 0
  var successCount = 0
  
  for record in healthRecords:
    if not record.hasKey("name") or not record.hasKey("http_status"):
      continue
      
    let pkgName = record["name"].getStr
    let status = record["http_status"].getInt
    let lastAccess = if record.hasKey("last_access_time"): record["last_access_time"].getStr else: "Never"
    
    let statusStr = if status == 0: "ERROR" else: $status
    let statusColor = if status == 404 or status == 410: "DEPRECATED" 
                     elif status >= 400 or status == 0: "FAILED"
                     else: "OK"
    
    case statusColor:
    of "DEPRECATED": inc deprecatedCount
    of "FAILED": inc failedCount
    of "OK": inc successCount
    
    # Format the output with fixed width columns
    let nameCol = if pkgName.len > 30: pkgName[0..27] & ".." else: pkgName
    let statusCol = if statusStr.len > 6: statusStr[0..5] else: statusStr
    let accessCol = if lastAccess.len > 20: lastAccess[0..19] else: lastAccess
    
    echo nameCol & repeat(" ", 30 - nameCol.len), " | ", 
        repeat(" ", 6 - statusCol.len) & statusCol, " | ", 
        accessCol & repeat(" ", 20 - accessCol.len)
   
  echo "----------------------------------------------------------"
  echo "Summary: ", successCount, " OK, ", deprecatedCount, " Deprecated, ", failedCount, " Failed"

proc removeDeprecated*(dryRun = false) =
  ## Remove deprecated packages (404/410 status) from packages.json and create PR
  echo "Loading deprecated packages from health database..."
  
  let healthDb = initHealthDatabase()
  defer: healthDb.close()
  
  # Get all deprecated packages (404/410 status)
  var deprecatedPackages: seq[tuple[name, url: string]] = @[]
  for row in healthDb.rows(sql"SELECT name, url FROM package_health WHERE http_status IN (404, 410) ORDER BY name"):
    deprecatedPackages.add((name: row[0], url: row[1]))
  
  if deprecatedPackages.len == 0:
    echo "No deprecated packages found in database."
    echo "Run 'check-pkg-health' first to check package health."
    return
  
  echo "Found ", deprecatedPackages.len, " deprecated packages to remove:"
  for pkg in deprecatedPackages:
    echo "  - ", pkg.name, " (", pkg.url, ")"
  
  if dryRun:
    echo "\nDry run mode - no changes will be made."
    return
  
  # Fetch current packages.json
  let c = githubapi.getClient()
  let body = c.getContent("https://cdn.jsdelivr.net/gh/nim-lang/packages@master/packages.json")
  var pkgs = parseJson(body)
  
  echo "\nOriginal packages.json contains ", pkgs.len, " packages"
  
  # Create a set of deprecated package names for fast lookup
  var deprecatedNames: HashSet[string]
  for pkg in deprecatedPackages:
    deprecatedNames.incl(pkg.name)
  
  # Filter out deprecated packages
  var newPkgs = newJArray()
  var removedCount = 0
  for pkg in pkgs:
    if pkg.hasKey("name"):
      let pkgName = pkg["name"].getStr
      if pkgName notin deprecatedNames:
        newPkgs.add(pkg)
      else:
        inc removedCount
        echo "Removing: ", pkgName
  
  echo "\nAfter removal: ", newPkgs.len, " packages remain (", removedCount, " removed)"
  
  if removedCount == 0:
    echo "No packages were removed (they may not exist in packages.json)"
    return
  
  # Prepare branch name and commit message
  let timestamp = format(now(), "yyyyMMdd-HHmmss")
  let branch = "remove-deprecated-packages-" & timestamp
  let message = "Remove " & $removedCount & " deprecated packages with 404/410 errors\n\n" &
                "The following packages have been removed because their repositories\n" &
                "are no longer accessible (HTTP 404/410 errors):\n\n"
  
  var prBody = "## Summary\n\n"
  prBody.add("This PR removes " & $removedCount & " deprecated packages from the Nim packages registry.\n\n")
  prBody.add("## Removed Packages\n\n")
  prBody.add("These packages have been identified as deprecated because their repository URLs\n")
  prBody.add("return HTTP 404 (Not Found) or 410 (Gone) status codes, indicating they are\n")
  prBody.add("no longer maintained or have been deleted.\n\n")
  prBody.add("| Package Name | Repository URL | Status |\n")
  prBody.add("|-------------|----------------|--------|\n")
  
  for pkg in deprecatedPackages:
    let status = healthDb.getValue(sql"SELECT http_status FROM package_health WHERE name = ?", pkg.name)
    prBody.add("| " & pkg.name & " | " & pkg.url & " | " & status & " |\n")
  
  prBody.add("\n## Verification\n\n")
  prBody.add("These packages were checked using `nimherd check-pkg-health` which performs\n")
  prBody.add("HTTP HEAD requests to verify repository accessibility.\n\n")
  prBody.add("- **Total packages before**: " & $pkgs.len & "\n")
  prBody.add("- **Total packages after**: " & $newPkgs.len & "\n")
  prBody.add("- **Packages removed**: " & $removedCount & "\n")
  
  echo "\nPreparing to create PR..."
  echo "Branch: ", branch
  echo "Commit message preview:"
  echo message
  
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
  let branchRef = "refs/heads/" & branch
  
  # Check if branch already exists
  if githubapi.branchExists(Org, "packages", branch):
    echo "Branch " & branch & " already exists, skipping creation"
  else:
    if not githubapi.createRef(Org, "packages", branchRef, masterSha):
      echo "Failed to create branch " & branch
      quit(1)
    echo "Created branch: ", branch
  
  # Get current packages.json file
  let (currentContent, fileSha) = githubapi.getFileContents(Org, "packages", "packages.json", "master")
  
  # Update packages.json
  let updatedContent = newPkgs.pretty.cleanupWhitespace
  
  var success = false
  if currentContent.len > 0:
    if currentContent != updatedContent:
      success = githubapi.updateFileContents(Org, "packages", "packages.json", message, updatedContent, fileSha, branch)
      if not success:
        echo "Failed to update packages.json"
        quit(1)
      echo "Updated packages.json on branch: ", branch
    else:
      echo "No changes to packages.json"
      return
  else:
    success = githubapi.createFileContents(Org, "packages", "packages.json", message, updatedContent, branch)
    if not success:
      echo "Failed to create packages.json"
      quit(1)
  
  # Create PR
  let prTitle = "Remove " & $removedCount & " deprecated packages with inaccessible repositories"
  let headRef = Org & ":" & branch
  
  echo "\nCreating pull request..."
  echo "Title: ", prTitle
  
  if githubapi.createPr("nim-lang", "packages", headRef, "master", prTitle, prBody):
    echo "Successfully created PR to remove deprecated packages!"
  else:
    echo "Failed to create PR"
    quit(1)

when isMainModule:
  dotenv.load()
  dispatchMulti(
    [outputList, cmdName = "list"],
    [run, cmdName = "run"],
    [dryRun, cmdName = "dry-run"],
    [checkPackageHealth, cmdName = "check-pkg-health"],
    [printHealthStatus, cmdName = "print-health"],
    [removeDeprecated, cmdName = "remove-deprecated"],
  )
