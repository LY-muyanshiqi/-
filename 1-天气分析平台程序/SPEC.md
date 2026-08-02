# 天气查看网站 — 技术规范文档 (SPEC)

> **版本**: v1.0  
> **日期**: 2026-07-31  
> **定位**: 面向电力负荷预测的天气数据查询与分析工具

---

## 1. 项目概述

### 1.1 核心目标
开发一个天气数据查看网站，服务于电力负荷预测场景。提供**可视化看板**（人工分析）和**结构化数据导出**（模型输入）两种使用模式。

### 1.2 关键用例
| 编号 | 场景 | 描述 |
|------|------|------|
| UC-1 | 日常负荷预判 | 查看过去N天实际 + 未来3天预报，判断负荷趋势 |
| UC-2 | 负荷-天气关联分析 | 上传负荷CSV，叠加天气曲线，直观发现相关性 |
| UC-3 | 模型数据准备 | 导出指定时间范围的结构化天气CSV，喂入ML模型或LLM |
| UC-4 | 多地点对比 | 同时查看中山市与广东省平均的天气差异 |

---

## 2. 技术栈

| 层级 | 选型 | 理由 |
|------|------|------|
| **前端框架** | Streamlit (Python) | 数据应用首选，零前端成本，原生图表支持 |
| **部署方式** | Streamlit Community Cloud + GitHub | 推送即部署，免费，自动HTTPS |
| **数据持久化** | SQLite (本地文件) | 零配置、Streamlit原生兼容、单文件便携 |
| **图表库** | Plotly (via `st.plotly_chart`) | 交互式、支持时间序列缩放/悬停、双Y轴叠加 |
| **数据源(主)** | Open-Meteo API | 免费、无需Key、历史ERA5-Land + 预报全覆盖 |
| **数据源(备)** | 和风天气 API | 国内访问快、当Open-Meteo不可用时自动切换 |
| **定时触发** | 外部Uptime监控 (cron-job.org/UptimeRobot) | 每30分钟ping应用，触发缓存刷新 |
| **LLM集成** | MVP不集成 | 架构预留接口，后续迭代加入 |

### 2.1 为什么不用纯前端方案？
- API Key 安全：密钥存储在 Streamlit Secrets，不暴露浏览器端
- 数据聚合：省平均需要多次API调用后计算，后端聚合更高效
- 持久化：需要SQLite存储历史数据，前端无法实现

### 2.2 为什么 Streamlit + 外部触发而不是独立后端？
- Streamlit Cloud 免费托管，零运维成本
- `st.cache_data(ttl=1800)` 天然控制API调用频率
- 外部ping服务（免费）解决"无人访问时数据不更新"问题
- 避免维护 FastAPI/Flask 等额外服务

---

## 3. 数据源设计

### 3.1 主数据源：Open-Meteo

| 端点 | 用途 | 参数 |
|------|------|------|
| `archive_api` (ERA5-Land) | 历史实际天气（>5天前） | 全部气象参数 |
| `forecast_api` | 未来3天逐小时预报 | 全部气象参数 |

**请求参数清单**（与负荷预测相关的全量气象参数）：
```
temperature_2m, apparent_temperature, relative_humidity_2m,
precipitation, rain, showers, snowfall,
wind_speed_10m, wind_direction_10m, wind_gusts_10m,
surface_pressure, mean_sea_level_pressure,
cloud_cover, cloud_cover_low, cloud_cover_mid, cloud_cover_high,
sunshine_duration,
dew_point_2m, evapotranspiration, vapour_pressure_deficit
```

### 3.2 备用数据源：和风天气

| 端点 | 用途 | 触发条件 |
|------|------|----------|
| `7天逐小时预报` | 未来3天预报 | Open-Meteo 超时/错误 |
| `历史天气` | 近期历史 | Open-Meteo 超时/错误 |

切换逻辑：Open-Meteo 请求超时（>10s）或返回 5xx → 自动 fallback 和风天气 → 页面顶部显示黄色警告条提示当前使用备用源。

### 3.3 调用策略
```
每次用户访问 / 外部ping触发时:
  1. 检查 st.cache_data TTL（1800秒）
  2. 缓存有效 → 直接返回
  3. 缓存过期 → 调用API拉取新数据 → 写入SQLite → 更新缓存
  
API调用合并:
  - 单次archive_api调用覆盖所有地点（逗号分隔坐标）
  - 单次forecast_api调用覆盖所有地点
  - 日均调用量: 48次 (30分钟间隔) × 2 (archive+forecast) ≈ 96次
```

---

## 4. 地点与数据聚合

### 4.1 地点定义

| 地点ID | 名称 | 类型 | 实现方式 |
|--------|------|------|----------|
| `zhongshan` | 中山市 | 单点城市 | 直接查询坐标 (22.52°N, 113.38°E) |
| `guangdong_avg` | 广东省平均 | 聚合计算 | 5个代表城市取算术平均 |

### 4.2 广东省平均 — 代表城市选取
```
广州 (23.13°N, 113.26°E) — 珠三角中心
深圳 (22.54°N, 114.06°E) — 珠三角东南
韶关 (24.80°N, 113.58°E) — 粤北
湛江 (21.27°N, 110.36°E) — 粤西
汕头 (23.35°N, 116.68°E) — 粤东
```
**聚合方式**: 各气象参数分别取5市算术平均（温度、湿度、风速等连续量）或求和（降水量等累积量）。

> **后续升级路径**: 如需更高精度，可引入 ERA5 格点数据（0.25°×0.25°），按面积/人口/用电量加权。

---

## 5. 功能模块

### 5.1 侧边栏控制面板（全局）
```
┌─────────────────────────┐
│  📍 地点选择            │
│  ○ 中山市  ○ 广东省平均  │
│  [可多选，同时展示]       │
│                         │
│  📅 时间范围             │
│  历史回溯: [7] 天 (1-30) │
│  预报天数: [3] 天 (固定)  │
│                         │
│  🌡️ 展示参数             │
│  ☑ 温度  ☑ 降水  ☑ 风   │
│  ☑ 日照  ☐ 气压  ☐ 露点 │
│  [影响可视化图表显示]     │
│                         │
│  📥 数据导出             │
│  [导出CSV] [导出JSON]    │
│                         │
│  ⚙️ 设置                │
│  默认历史天数: [7]       │
│  自动刷新: [开启/关闭]    │
│  数据源状态: 🟢 正常      │
└─────────────────────────┘
```

### 5.2 主区域 — Tab 页签布局

#### Tab 1: 📊 天气总览

**概览卡片行**（顶部，4列）:
```
┌──────────┬──────────┬──────────┬──────────┐
│ 当前温度  │ 今日降水  │ 平均风速  │ 日照小时  │
│  32.5°C  │  2.3 mm  │ 12 km/h  │  6.2 h   │
│ 体感 38°C│ 概率 65% │ 东南风    │ 云量 45% │
└──────────┴──────────┴──────────┴──────────┘
```

**时序图表**（主体，从上到下）:

1. **温度曲线** — 折线图
   - 实际温度 + 体感温度（双线）
   - X轴: 时间（逐小时），Y轴: °C
   - 历史部分用实线，预报部分用虚线区分
   - 标注高温/低温极值点

2. **降水柱状图** — 柱状图 + 累积降水折线
   - 逐小时降水量（柱）+ 24h累积降水量（线，右Y轴）
   - 标注暴雨阈值线（50mm/24h）

3. **风况组合图** — 风速折线 + 风向箭头
   - 风速折线 + 风向简化为8方位标记点
   
4. **日照小时数面积图** — 面积图
   - 逐小时日照时长 (秒/小时，换算为小时) 面积填充
   - 叠加云量（%）虚线（右Y轴，倒置）

**图表交互**:
- Plotly 原生缩放（框选时间范围）、悬停显示详情
- 所有图表共享X轴缩放（subplot 联动）

#### Tab 2: 🔗 负荷叠加分析

**负荷数据上传区**:
```
┌─────────────────────────────────────┐
│ 📤 上传负荷CSV文件                    │
│ [选择文件] 支持格式: 时间戳+负荷值(MW) │
│                                     │
│ 已加载: guangdong_load_202607.csv    │
│ 时间范围: 2026-07-01 ~ 2026-07-30    │
│ 数据点数: 720 (逐小时)                │
│ [清除数据]                           │
└─────────────────────────────────────┘
```

**叠加图表**:

1. **降水-负荷叠加图**（核心图表）
   - 负荷曲线（折线，左Y轴，MW）+ 降水量（柱，右Y轴，mm，倒置）
   - 双Y轴，直观展示降水事件与负荷变化的时序关系
   - 支持拖拽选择时间窗口放大

2. **温度-负荷散点图**
   - X轴: 温度(°C)，Y轴: 负荷(MW)
   - 按季节/月份着色
   - 可选叠加线性回归趋势线

3. **多因子对比面板**
   - 用户自选X轴气象参数 vs 负荷
   - 可选图表类型: 散点图 / 柱状图 / 相关性热力图

**相关性统计卡片**（叠加图右侧或下方）:
```
┌──────────────────────────┐
│ 温度-负荷 Pearson r: 0.87│
│ 降水-负荷 Pearson r: 0.32│
│ 风速-负荷 Pearson r:-0.21│
│ 日照-负荷 Pearson r: 0.65│
└──────────────────────────┘
```

#### Tab 3: 📋 数据表格与导出

**数据表格**:
- 展示当前加载的全部天气数据的表格视图
- 列: 时间 | 温度 | 体感温度 | 湿度 | 降水 | 风速 | 风向 | 气压 | 云量 | 日照 | ...
- 支持列排序、筛选
- 分页显示（每页48行 = 2天逐小时）
- 可勾选要导出的列

**导出功能**:
- **CSV导出**: 宽表格式，每行一个时间戳，每列一个参数
  ```csv
  datetime,location,temp_2m,apparent_temp,rh_2m,precip,wind_speed_10m,wind_dir_10m,pressure_msl,cloud_cover,sunshine_duration,...
  2026-07-31T14:00,zhongshan,32.5,38.2,65,0.0,12.3,135,1008.5,45,3200,...
  ```
- **JSON导出**: 结构化层级格式（可选）
  ```json
  {
    "location": "zhongshan",
    "generated_at": "2026-07-31T14:30:00+08:00",
    "data": [
      {"datetime": "2026-07-31T14:00", "temp_2m": 32.5, ...}
    ]
  }
  ```
- 支持选择导出时间范围（当前可视范围 / 全部已加载数据 / 自定义范围）

---

## 6. 数据持久化设计

### 6.1 SQLite 表结构

```sql
-- 原始天气数据（逐小时，长期存储）
CREATE TABLE weather_hourly (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    location_id TEXT NOT NULL,          -- 'zhongshan' | 'guangzhou' | ...
    datetime TEXT NOT NULL,             -- ISO 8601 '2026-07-31T14:00+08:00'
    data_type TEXT NOT NULL,            -- 'historical' | 'forecast'
    source TEXT NOT NULL,               -- 'openmeteo' | 'qweather'
    temp_2m REAL,
    apparent_temp REAL,
    relative_humidity_2m REAL,
    precipitation REAL,
    rain REAL,
    showers REAL,
    snowfall REAL,
    wind_speed_10m REAL,
    wind_direction_10m REAL,
    wind_gusts_10m REAL,
    surface_pressure REAL,
    mean_sea_level_pressure REAL,
    cloud_cover REAL,
    cloud_cover_low REAL,
    cloud_cover_mid REAL,
    cloud_cover_high REAL,
    sunshine_duration REAL,
    dew_point_2m REAL,
    evapotranspiration REAL,
    vapour_pressure_deficit REAL,
    fetched_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(location_id, datetime, data_type)
);

CREATE INDEX idx_weather_loc_time ON weather_hourly(location_id, datetime);

-- 聚合地点映射（广东省平均的虚拟地点）
CREATE TABLE location_meta (
    location_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    is_aggregate INTEGER DEFAULT 0,    -- 1 = 聚合计算得出
    parent_ids TEXT                     -- 聚合来源: 'guangzhou,shenzhen,...'
);

-- 用户设置（持久化到本地SQLite）
CREATE TABLE user_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- 默认值: {'default_history_days': '7', 'auto_refresh': 'true', 'theme': 'light'}
```

### 6.2 数据清理策略
- 预报数据超过7天自动标记过期（可通过设置调整）
- 历史数据永久保留（SQLite单文件预计年增长 ~50MB，可接受）
- 提供手动"清理过期预报"按钮

---

## 7. 负荷CSV格式规范

### 7.1 标准输入格式

**最简格式**（自动识别）:
```csv
datetime,load_mw
2026-07-01T00:00,3240.5
2026-07-01T01:00,3102.3
2026-07-01T02:00,2987.1
...
```

**扩展格式**（手动映射列名）:
```csv
时间,中山负荷MW,广州负荷MW,全省总负荷MW
2026-07-01 00:00,1240.5,2100.3,8230.8
2026-07-01 01:00,1187.2,2005.1,7890.2
...
```

### 7.2 解析规则
1. 自动检测编码（UTF-8 / GBK）
2. 自动识别时间戳格式（ISO 8601 / `YYYY-MM-DD HH:MM` / `YYYY/MM/DD HH:MM`）
3. 列名模糊匹配: `load`、`mw`、`负荷`、`功率` 均识别为负荷列
4. 如果多列匹配，弹出下拉框让用户选择目标列
5. 时间对齐: 负荷数据与天气数据按小时对齐，缺失时间点标记为空

---

## 8. 刷新与缓存策略

```
数据流:
  [外部Ping每30min] → Streamlit App被唤醒 
  → st.cache_data检查TTL → TTL过期则拉新数据 
  → 写入SQLite → 更新缓存 → 前端渲染

st.cache_data 配置:
  - TTL: 1800秒 (30分钟)
  - max_entries: 10
  - 按 (location_id, data_type) 组合缓存

边界情况:
  - API超时(>10s): 自动切换备用源 → 页面警告条
  - 双源均失败: 展示SQLite中最近一次成功数据 + 红色错误提示 + "数据已过期X小时"
  - 冷启动(无历史数据): 引导页提示"正在首次拉取数据，请稍候..."
  - Streamlit Cloud睡眠: 免费版15分钟无访问自动休眠，外部ping可唤醒
```

---

## 9. 错误处理矩阵

| 场景 | 用户可见 | 系统行为 |
|------|----------|----------|
| Open-Meteo超时 | ⚠️ 黄色警告："主数据源响应慢，已切换备用源" | fallback 和风天气 |
| 双源均失败 | 🔴 红色错误："数据更新失败，显示最近可用数据(2小时前)" | 读SQLite最后缓存 |
| SQLite写入失败 | 🔴 红色错误 + "数据存储异常，请检查磁盘空间" | 数据仅内存缓存 |
| 负荷CSV解析失败 | ⚠️ 黄色提示 + 具体错误行号 | 跳过错误行，继续解析 |
| 负荷CSV无匹配列 | ⚠️ 弹窗："未检测到负荷列，请手动选择" | 显示列名下拉框 |
| 网络断开 | 🔴 顶部Banner："网络连接异常，数据可能不是最新" | 展示本地缓存数据 |
| API返回空数据 | ⚠️ 黄色提示："部分地点/时段数据缺失" | 缺失值图表留空 |
| 首次启动无缓存 | ℹ️ 蓝色信息："正在获取天气数据..." | 加载动画 + 自动重试 |

---

## 10. 页面布局总览

```
┌──────────────────────────────────────────────────────────────┐
│  🌤️ 天气负荷分析平台                          🟢 数据正常      │
├──────────┬───────────────────────────────────────────────────┤
│          │  [📊 天气总览] [🔗 负荷叠加] [📋 数据表格]         │
│ 📍 地点  │                                                   │
│ ○ 中山市 │  ┌──── 概览卡片行 ────────────────────────────┐   │
│ ○ 广东省 │  │ 32.5°C │ 2.3mm │ 12km/h │ 6.2h  │ ...  │   │
│          │  └──────────────────────────────────────────┘   │
│ 📅 时间  │                                                   │
│ 历史[7]天│  ┌──── 温度曲线 (Plotly) ────────────────────┐   │
│ 预报[3]天│  │  ╱‾‾‾‾╲   ╱╲  ╱╲                         │   │
│          │  │ ╱      ╲╱  ╲╱  ╲╱╲                       │   │
│ 🌡️ 参数 │  └──────────────────────────────────────────┘   │
│ ☑ 温度   │                                                   │
│ ☑ 降水   │  ┌──── 降水柱状图 ──────────────────────────┐   │
│ ☑ 风     │  │  ▐█▌  ▐█▌     ▐█▌▐█▌                    │   │
│ ☑ 日照   │  │  ▐█▌  ▐█▌▐█▌  ▐█▌▐█▌▐█▌                 │   │
│ ☐ 气压   │  └──────────────────────────────────────────┘   │
│ ☐ 露点   │                                                   │
│          │  ┌──── 风况 + 日照图 ────────────────────────┐   │
│ ⚙️ 设置  │  │  ...                                       │   │
│ [导出CSV]│  └──────────────────────────────────────────┘   │
│          │                                                   │
└──────────┴───────────────────────────────────────────────────┘
```

---

## 11. 项目结构

```
weather-load-platform/
├── app.py                      # Streamlit 主入口
├── config.py                   # 配置：地点坐标、默认参数、API设置
├── requirements.txt            # Python依赖
├── packages.txt                # 系统依赖（如有）
├── .streamlit/
│   ├── config.toml             # Streamlit主题/服务器配置
│   └── secrets.toml            # API密钥（gitignore保护）
├── src/
│   ├── __init__.py
│   ├── api/
│   │   ├── __init__.py
│   │   ├── openmeteo.py        # Open-Meteo API 封装
│   │   ├── qweather.py         # 和风天气 API 封装
│   │   └── fallback.py         # 双源切换逻辑
│   ├── db/
│   │   ├── __init__.py
│   │   ├── models.py           # SQLite 表定义与CRUD
│   │   └── migrations.py       # 数据库迁移
│   ├── aggregation/
│   │   ├── __init__.py
│   │   └── province_avg.py     # 广东省平均计算
│   ├── charts/
│   │   ├── __init__.py
│   │   ├── weather_charts.py   # 天气总览图表
│   │   ├── load_overlay.py     # 负荷叠加图表
│   │   └── cards.py            # 概览卡片
│   ├── export/
│   │   ├── __init__.py
│   │   ├── csv_writer.py       # CSV宽表导出
│   │   └── json_writer.py      # JSON导出
│   └── utils/
│       ├── __init__.py
│       ├── time_utils.py       # 时间处理/时区转换
│       └── csv_parser.py       # 负荷CSV解析
├── data/
│   └── weather.db              # SQLite数据库（gitignore）
├── tests/
│   ├── test_api.py
│   ├── test_aggregation.py
│   ├── test_csv_parser.py
│   └── test_db.py
└── README.md
```

---

## 12. 依赖清单

```
# requirements.txt
streamlit>=1.28.0
plotly>=5.17.0
pandas>=2.1.0
numpy>=1.24.0
requests>=2.31.0
openmeteo-requests>=1.0.0     # Open-Meteo 官方Python客户端
httpx>=0.25.0                  # 异步HTTP（和风天气客户端）
scipy>=1.11.0                  # Pearson相关系数计算
pytz>=2023.3                   # 时区处理
```

---

## 13. 风险与待决议题

### 13.1 已知风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| Open-Meteo 国内访问慢 | 数据加载超时 | 备用和风天气源 + 10s超时阈值 + 缓存兜底 |
| Streamlit Cloud 免费版睡眠 | 数据不再自动刷新 | 外部 ping 每30分钟唤醒 + 用户访问时自然唤醒 |
| ERA5-Land 5天延迟 | 最近5天没有历史实际数据 | Open-Meteo Forecast API 的历史端点可获取近期实际观测 |
| SQLite 并发写入 | 多用户同时触发刷新导致锁 | Streamlit 单线程模型天然避免；写操作用 WAL 模式 |
| 和风天气需实名认证 | 无法获取API Key | MVP 可只用 Open-Meteo，备用源占位代码预留 |
| 负荷CSV格式千差万别 | 解析失败率高 | 宽松匹配策略 + 手动列映射UI |

### 13.2 待决议题（MVP后可迭代）

1. **广东省平均精度升级** — 是否需要引入 ERA5 格点数据做空间加权？
2. **LLM集成** — 何时引入站内AI分析面板？最小实现方案：导出CSV → Claude API → 自然语言解读
3. **多用户支持** — 目前为单用户设计，后续是否需要登录/多用户数据隔离？
4. **负荷预测模型集成** — 是否需要内置简单的负荷预测模型（如线性回归基线），直接在页面上展示预测值？
5. **移动端适配** — Streamlit 默认响应式但对手机体验一般，是否需要专门适配？

---

## 14. 里程碑计划

| 阶段 | 内容 | 预计工时 |
|------|------|----------|
| **M1 — 数据核心** | Open-Meteo API封装、SQLite建表、双地点数据拉取、缓存策略 | 2天 |
| **M2 — 可视化** | 天气总览Tab：概览卡片 + 温度/降水/风/日照4张Plotly图表 | 2天 |
| **M3 — 负荷叠加** | CSV解析器、负荷上传UI、降水-负荷叠加图、相关性统计 | 2天 |
| **M4 — 导出与设置** | CSV/JSON导出、用户设置持久化、数据表格Tab | 1天 |
| **M5 — 容错与部署** | 双源切换、错误处理、Streamlit Cloud部署、外部ping配置 | 1天 |
| **M6 — 测试与文档** | 单元测试、README、使用说明 | 1天 |
| **合计** | | **~9天** |

---

## 15. 附录：关键API调用示例

### Open-Meteo Archive 请求（历史数据）
```
GET https://archive-api.open-meteo.com/v1/archive
  ?latitude=22.52&longitude=113.38
  &start_date=2026-07-24&end_date=2026-07-30
  &hourly=temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m,wind_direction_10m,sunshine_duration,cloud_cover,...
  &timezone=Asia/Shanghai
```

### Open-Meteo Forecast 请求（预报数据）
```
GET https://api.open-meteo.com/v1/forecast
  ?latitude=22.52&longitude=113.38
  &hourly=temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m,wind_direction_10m,sunshine_duration,cloud_cover,...
  &forecast_days=3
  &timezone=Asia/Shanghai
```

---

> **文档状态**: ✅ 待审核  
> **下一步**: 请审阅此SPEC，确认无异议后我将按里程碑M1开始编码实现。
