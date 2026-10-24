-- BOSS 模块注册表

return {
    { name = "Zodiac",           file = "scripts.bosses.zodiac" },

    -- Man in the Moon 模块同时管理本体与 Moon Hand。
    { name = "Man in the Moon",  file = "scripts.bosses.maninthemoon" },

    -- 第三个 BOSS：Gambit（506）+ 六面骰（507）。
    { name = "Gambit",           file = "scripts.bosses.gambit" },

    -- 让 BOSS 自然出现在 BOSS 房（StageAPI 或运行时替换）
    { name = "Boss Pool",        file = "scripts.bosses.pool",
      noEntity = true },

    -- 再加模块就在这儿添一行，并在 content/entities2.xml 里加对应的 <entity>。
}
