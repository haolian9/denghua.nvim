it shows `^ ' .` marks as inline extmarks while editing

https://github.com/user-attachments/assets/114490f9-6b05-497c-98e3-352dfaf4a576


## design choices, features, limits
* show win-local marks: `'` last jump
* show buf-local marks: `^` last insert, `.` last change
* only show them in the current/focused window/buffer at the same time

## status
* it just works
* i found showing inline extmarks is just too distrubing
* due to [vim's design](https://github.com/neovim/neovim/issues/29820), i see no need to continue.

## todo
* [ ] `g;`, `g,`

## prerequisites
* nvim 0.10.*
* haolian9/infra.nvim

## usage
my personal config
```
do --denghua
  do --:Denghua
    local spell = cmds.Spell("Denghua", function(args) assert(require("denghua")[args.op])(ni.get_current_buf()) end)
    spell:add_arg("op", "string", false, "activate", cmds.ArgComp.constant({ "activate", "deactivate" }))
    cmds.cast(spell)
  end

  ex.eval("cnoreabbrev %s %s", "dghw", "Denghua")
end
```


## about the name

黄梅时节家家雨，青草池塘处处蛙。  
有约不来过夜半，闲敲棋子落灯花。  
