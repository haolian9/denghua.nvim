it shows `^ ' .` marks of a buffer with inline extmarks during editing

## design choices, features, limits
* show buf-local marks: `^` last insert, `'` last jump, `.` last change
* only show them for the current/focused window/buffer at the same time

## status
* just works

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
    spell:add_arg("op", "string", false, "attach", cmds.ArgComp.constant({ "attach", "detach" }))
    cmds.cast(spell)
  end

  ex.eval("cnoreabbrev %s %s", "dghw", "Denghua")
end
```


## about the name

黄梅时节家家雨，青草池塘处处蛙。  
有约不来过夜半，闲敲棋子落灯花。  
