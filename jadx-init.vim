" jadx-init.vim — Default configuration for jadx.nvim
"
" This file is sourced automatically by the jadx plugin on startup.
" To customize, copy this file to ~/.config/nvim/jadx-init.vim and edit
" your copy.  User overrides are loaded after this default, so any
" settings you define there will take precedence.
"
" ─── General Neovim settings ─────────────────────────────────────────────────

" Case-insensitive search by default; smart-case when uppercase is used.
set ignorecase
set smartcase

" Show line numbers (helps when navigating decompiled code).
set number

" Highlight search matches as you type.
set incsearch
set hlsearch

" Keep some context lines visible when scrolling.
set scrolloff=5

" ─── Keybindings ─────────────────────────────────────────────────────────────
"
" These mappings use <leader> (default: \) as a prefix.  Override <leader>
" in your jadx-init.vim if you prefer a different key.

" Open a class by fully-qualified name (prompts for input).
nnoremap <leader>jo :JadxOpen<Space>

" Hot-load a new APK/DEX/JAR file (prompts for path).
nnoremap <leader>jl :JadxLoad<Space>

" Fuzzy-search classes, methods, and fields with fzf.
nnoremap <leader>js :JadxSearch<CR>

" Open the jadx status buffer to see server activity and logs.
nnoremap <leader>ji :JadxStatus<CR>

" Go to definition under cursor (standard LSP binding).
nnoremap gd <cmd>lua vim.lsp.buf.definition()<CR>

" Show hover information for symbol under cursor.
nnoremap K <cmd>lua vim.lsp.buf.hover()<CR>
