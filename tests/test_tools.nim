import std/[unittest, json, os, strutils]
import nimherd


suite "updateUrls":
  test "updates homepage and url to new org URL":
    let tmp = getTempDir() / "test_pkg.nimble"
    let initial = """
name = "pkg"
version = "0.1.0"
homepage = "https://example.com/pkg"
url = "https://example.com/pkg"
"""
    writeFile(tmp, initial)
    let newUrl = "https://github.com/nim-community/pkg"
    let changed = updateUrls(tmp, newUrl)
    check changed == true
    let after = readFile(tmp)
    check after.find("homepage") >= 0
    check after.find(newUrl) >= 0
    check after.find("url") >= 0

 
