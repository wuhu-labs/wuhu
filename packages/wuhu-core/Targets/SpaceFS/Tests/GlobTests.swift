import SpaceFS
import Testing

struct GlobTests {
  @Test func `a single star matches within one segment only`() {
    #expect(Glob.matches("*.md", "foo.md"))
    #expect(!Glob.matches("*.md", "foo.txt"))
    #expect(!Glob.matches("*.md", "dir/foo.md"))
  }

  @Test func `a double star crosses segment boundaries`() {
    #expect(Glob.matches("**/*.md", "a/b/foo.md"))
    #expect(Glob.matches("**", "a/b/c"))
    #expect(!Glob.matches("**/*.md", "foo.md"))
  }

  @Test func `question mark matches a single non-separator character`() {
    #expect(Glob.matches("a?c", "abc"))
    #expect(!Glob.matches("a?c", "a/c"))
    #expect(!Glob.matches("a?c", "ac"))
  }

  @Test func `regex metacharacters in the pattern are matched literally`() {
    #expect(Glob.matches("file.name", "file.name"))
    #expect(!Glob.matches("file.name", "fileXname"))
    #expect(Glob.matches("a+b", "a+b"))
    #expect(!Glob.matches("a+b", "aaab"))
    #expect(Glob.matches("v(1)", "v(1)"))
  }

  @Test func `a compound double-star pattern matches a nested path`() {
    #expect(Glob.matches("**/*.swift", "src/main.swift"))
    #expect(Glob.matches("src/**/*.swift", "src/a/b/main.swift"))
  }
}
