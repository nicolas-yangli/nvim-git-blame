from datetime import datetime
from pathlib import Path
import subprocess
import sys

import pynvim


@pynvim.plugin
class NvimGitBlame:
    def __init__(self, nvim):
        self._nvim = nvim
        self._buffer_blame_info = {}
        self._namespace = nvim.call('nvim_create_namespace', 'nvim-git-blame-messages')

    @pynvim.autocmd('BufReadPre', eval='{"afile": expand("<afile>"), "abuf": expand("<abuf>")}')
    def on_buf_read_pre(self, data):
        self._load_blame_info(data['afile'], int(data['abuf']))

    @pynvim.autocmd('BufWritePost', eval='{"afile": expand("<afile>"), "abuf": expand("<abuf>")}')
    def on_buf_write_post(self, data):
        self._load_blame_info(data['afile'], int(data['abuf']))

    def _load_blame_info(self, filename, buffer_num):
        filepath = Path(filename).resolve()
        file_dir = filepath.parent
        try:
            blame_data = subprocess.check_output(
                    ['git', 'blame', '--incremental', str(filepath)],
                    stdin=subprocess.DEVNULL, cwd=str(file_dir)).decode('utf-8')
            blame_info = self._parse_blame_data(blame_data.splitlines())
            self._buffer_blame_info[buffer_num] = blame_info
        except subprocess.CalledProcessError:
            pass

    @pynvim.autocmd('BufUnload', eval='expand("<abuf>")')
    def free_blame_info(self, abuf):
        buffer_num = int(abuf)
        if buffer_num in self._buffer_blame_info:
            del self._buffer_blame_info[buffer_num]

    @pynvim.autocmd('CursorMoved', eval='{"abuf": expand("<abuf>"), "nu": line(".")}')
    def on_cursor_moved(self, data):
        self._repaint(int(data['abuf']), data['nu'] - 1)

    def _repaint(self, buffer_num, nu):
        self._nvim.call('nvim_buf_clear_namespace', 0, self._namespace, 0, -1)
        #self._nvim.call('nvim_buf_set_virtual_text', 0, self._namespace, nu, [[' buffer_num: {}, nu: {}, buffer_blame_info: {}'.format(buffer_num, nu, self._buffer_blame_info), 'Comment']], {})
        blame_text = self._format_blame(buffer_num, nu)
        if blame_text:
            self._nvim.call('nvim_buf_set_virtual_text', 0, self._namespace, nu, [[blame_text, 'Comment']], {})

    def _format_blame(self, buffer_num, nu):
        buffer_blame_info = self._buffer_blame_info.get(buffer_num)
        if not buffer_blame_info:
            return
        try:
            blame_info = buffer_blame_info[nu]
            return '    {} - {} {}: {}'.format(blame_info.sha1[:8],
                    datetime.fromtimestamp(blame_info.author_time).strftime('%Y-%m-%d %H:%M'),
                    blame_info.author, blame_info.summary)
        except IndexError:
            pass

    @classmethod
    def _parse_blame_data(cls, blame_lines):
        sha1_cache = {}
        ret = []
        state = 0
        for line in blame_lines:
            if state == 0:
                print(line, end='')
                (sha1, _, line_start, line_num) = line.split(' ')
                line_start = int(line_start)
                line_num = int(line_num)
                if sha1 in sha1_cache:
                    cached_info = sha1_cache[sha1]
                    author = cached_info.author
                    author_time = cached_info.author_time
                    author_tz = cached_info.author_tz
                    summary = cached_info.summary
                else:
                    author = 'N/A'
                    author_time = 0
                    author_tz = 'Z'
                    summary = ''
                state = 1
            elif state == 1:
                li = line.split(' ', 1)
                key = li[0]
                if key == 'author':
                    author = li[1]
                elif key == 'author-time':
                    author_time = int(li[1])
                elif key == 'author-tz':
                    author_tz = li[1]
                elif key == 'summary':
                    summary = li[1]
                elif key == 'filename':
                    print('{} {} {}\n'.format(sha1, line_start, line_num))
                    info = _BlameInfo(sha1, author, author_time, author_tz, summary)
                    sha1_cache[sha1] = info
                    for nu in range(line_start - 1, line_start - 1 +line_num):
                        if nu >= len(ret):
                            ret.extend([None] * (nu - len(ret) + 1))
                        ret[nu] = info
                    state = 0
        return ret


class _BlameInfo:
    def __init__(self, sha1, author, author_time, author_tz, summary):
        self.sha1 = sha1
        self.author = author
        self.author_time = author_time
        self.author_tz = author_tz
        self.summary = summary
