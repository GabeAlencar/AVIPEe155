-- Fills a code block from a file, so the page always shows the current source:
--   ```{.systemverilog include="../fpga/src/counter.sv"}
--   ```
-- The path is relative to the .qmd file.

function CodeBlock(el)
  local path = el.attributes["include"]
  if not path then return nil end
  local dir = pandoc.path.directory(quarto.doc.input_file)
  local f = io.open(pandoc.path.join({dir, path}), "r")
  if not f then
    error("include-code: cannot open " .. path)
  end
  el.text = f:read("a"):gsub("%s+$", "")
  f:close()
  el.attributes["include"] = nil
  return el
end
