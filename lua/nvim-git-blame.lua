-- nvim_git_blame.lua

local M = {}

local buffer_blame_info = {}
local namespace = nil

local function get_namespace()
  if namespace == nil then
    namespace = vim.api.nvim_create_namespace('nvim-git-blame-messages')
  end
  return namespace
end

-- Corresponds to _parse_blame_data from the Python version
local function parse_blame_data(blame_lines)
  local sha1_cache = {}
  local ret = {}
  local state = 0
  local sha1, dest_line, num_lines
  local author, author_time, author_tz, summary

  for _, line in ipairs(blame_lines) do
    if line ~= '' then
      if state == 0 then
        local parts = vim.split(line, ' ', {trimempty = true})
        if #parts >= 3 then
            sha1 = parts[1]
            dest_line = tonumber(parts[3])
            num_lines = tonumber(parts[4])

            if sha1_cache[sha1] then
              local cached_info = sha1_cache[sha1]
              author = cached_info.author
              author_time = cached_info.author_time
              author_tz = cached_info.author_tz
              summary = cached_info.summary
            else
              author = 'N/A'
              author_time = 0
              author_tz = 'Z'
              summary = ''
            end
            state = 1
        end
      elseif state == 1 then
        local key, value = line:match("([^ ]+) (.*)")
        if key then
            if key == 'author' then
              author = value
            elseif key == 'author-time' then
              author_time = tonumber(value)
            elseif key == 'author-tz' then
              author_tz = value
            elseif key == 'summary' then
              summary = value
            elseif key == 'filename' then
              local info = {
                sha1 = sha1,
                author = author,
                author_time = author_time,
                author_tz = author_tz,
                summary = summary
              }
              sha1_cache[sha1] = info
              for i = 0, num_lines - 1 do
                ret[dest_line + i] = info
              end
              state = 0
            elseif key == 'boundary' then
                state = 0
            end
        end
      end
    end
  end
  return ret
end

-- Corresponds to _load_blame_info
local function load_blame_info(filename, buffer_num)
  if not filename or filename == '' then return end
  local filepath = vim.fs.abspath(filename)
  if not filepath then return end
  local file_dir = vim.fs.dirname(filepath)

  -- Check if it's a file and inside a git repository
  if not vim.loop.fs_stat(filepath) or not vim.fn.isdirectory(file_dir) then return end
  local git_root_cmd = {'git', '-C', file_dir, 'rev-parse', '--show-toplevel'}
  local git_root_job = vim.system(git_root_cmd, {text = true}):wait()
  if git_root_job.code ~= 0 then
    return -- Not a git repository
  end

  local result = vim.system({ 'git', 'blame', '--incremental', filepath }, { cwd = file_dir, text = true }):wait()

  if result.code == 0 then
    local blame_data = vim.split(result.stdout, '\n', {trimempty = false})
    local blame_info = parse_blame_data(blame_data)
    buffer_blame_info[buffer_num] = blame_info
  else
    buffer_blame_info[buffer_num] = nil
  end
end

-- Corresponds to _format_blame
local function format_blame(buffer_num, nu)
  local blame_for_buf = buffer_blame_info[buffer_num]
  if not blame_for_buf then return nil end

  local blame_info = blame_for_buf[nu + 1] -- nu is 0-based, table is 1-based
  if not blame_info then return nil end

  local formatted_time = os.date('%Y-%m-%d %H:%M', blame_info.author_time)
  return string.format('    %s - %s %s: %s',
    string.sub(blame_info.sha1, 1, 8),
    formatted_time,
    blame_info.author,
    blame_info.summary
  )
end

-- Corresponds to _repaint
local function repaint(buffer_num)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    if buf ~= buffer_num then return end -- Only repaint for the active buffer in the current window

    local nu = vim.api.nvim_win_get_cursor(win)[1] - 1
    vim.api.nvim_buf_clear_namespace(buffer_num, get_namespace(), 0, -1)
    local blame_text = format_blame(buffer_num, nu)
    if blame_text then
        vim.api.nvim_buf_set_virtual_text(buffer_num, get_namespace(), nu, {{blame_text, 'Comment'}}, {})
    end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('NvimGitBlame', { clear = true })

  vim.api.nvim_create_autocmd({'BufReadPost', 'BufWritePost'}, {
    group = group,
    pattern = '*',
    callback = function(args)
      vim.schedule(function()
        local filetype = vim.api.nvim_buf_get_option(args.buf, 'filetype')
        if filetype == 'gitcommit' or filetype == 'git' then return end
        load_blame_info(vim.api.nvim_buf_get_name(args.buf), args.buf)
      end)
    end
  })

  vim.api.nvim_create_autocmd('BufUnload', {
    group = group,
    pattern = '*',
    callback = function(args)
      buffer_blame_info[args.buf] = nil
    end
  })

  vim.api.nvim_create_autocmd({'CursorMoved', 'InsertLeave'}, {
    group = group,
    pattern = '*',
    callback = function(args)
        if buffer_blame_info[args.buf] then
            repaint(args.buf)
        end
    end
  })

  vim.api.nvim_create_autocmd('InsertEnter', {
    group = group,
    pattern = '*',
    callback = function(args)
      vim.api.nvim_buf_clear_namespace(args.buf, get_namespace(), 0, -1)
    end
  })
end

return M
