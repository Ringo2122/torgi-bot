#!/usr/bin/env ruby
# encoding: utf-8
#
# Сторож торгов: следит за разделами недвижимости и транспорта на e-auction.by, ipmtorgi.by
# beltorgi.by, cpo.by и konfiskat.by, шлёт в Telegram карточку по каждому новому лоту: название, фото, цена, дата окончания приёма заявок.
#
#   ruby tgbot.rb --init    первый запуск: запомнить текущие лоты и НИЧЕГО не слать
#   ruby tgbot.rb           обычный запуск: прислать только новые
#   ruby tgbot.rb --test    проверить связь с Telegram
#
# Токен НЕ хранится в коде. Он читается из ~/.torgi/token (chmod 600) или из ENV['TG_TOKEN'].
require 'json'
require 'fileutils'
require 'shellwords'
require 'time'
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Площадки печатают минское время без указания зоны, а сервер обычно живёт в UTC.
# Прибиваем зону, чтобы дедлайны не уезжали на три часа.
ENV['TZ'] = 'Europe/Minsk'

HOME     = File.expand_path(ENV['TORGI_HOME'] || '~/.torgi')
SEEN     = File.join(HOME, 'seen.json')
LOG      = File.join(HOME, 'bot.log')
LOCK     = File.join(HOME, 'lock')
TMPIMG   = File.join(HOME, 'photo.tmp')
UA       = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
MAX_SEND = (ENV['MAX_SEND'] || 25).to_i   # предохранитель от лавины сообщений
FRESH_DAYS = (ENV['FRESH_DAYS'] || 3).to_i # старше — не новость, даже если бот видит лот впервые
FileUtils.mkdir_p(HOME)

SECTIONS = [
  ['e-auction.by', 'Недвижимость',           'https://e-auction.by/nedvizhimost/'],
  ['e-auction.by', 'Легковые авто',          'https://e-auction.by/legkovye_avtomobili/'],
  ['e-auction.by', 'Грузовые и автобусы',    'https://e-auction.by/gruzovaya_tekhnika_i_avtobusy/'],
  ['ipmtorgi.by',  'Недвижимость',           'https://ipmtorgi.by/auctions/nedvizhimost/'],
  ['ipmtorgi.by',  'Транспорт и спецтехника','https://ipmtorgi.by/auctions/transport-i-spetstekhnika/'],
  ['beltorgi.by',  'Недвижимость',           'https://beltorgi.by/nedvizhimost/'],
  ['beltorgi.by',  'Легковые авто',          'https://beltorgi.by/legkovye-avto/'],
  ['beltorgi.by',  'Грузовые и автобусы',    'https://beltorgi.by/gruzovye-avto/'],
  ['beltorgi.by',  'Грузовые и автобусы',    'https://beltorgi.by/avtobusy/'],
  ['cpo.by',       'Недвижимость',           'https://www.cpo.by/auctions/filter/section-is-nedvizhimost/apply/'],
  ['cpo.by',       'Транспорт и спецтехника','https://www.cpo.by/auctions/filter/section-is-transport-i-spetstekhnika/apply/'],
  ['konfiskat.by', 'Автотранспорт',          'https://konfiskat.by/avtotransport/auktsiony/'],
  ['konfiskat.by', 'Недвижимость',           'https://konfiskat.by/nedvizhimost/auktsiony/']
].freeze

def log(msg)
  line = "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}  #{msg}"
  warn line
  File.open(LOG, 'a') { |f| f.puts line }
rescue StandardError
  nil
end

def token
  @token ||= (ENV['TG_TOKEN'] || (File.exist?(File.join(HOME, 'token')) ? File.read(File.join(HOME, 'token')).strip : '')).to_s
  abort("нет токена: положите его в #{File.join(HOME, 'token')} или задайте TG_TOKEN") if @token.empty?
  @token
end

def api(method, args = [])
  cmd = ['curl', '-sS', '-m', '60', '--retry', '2', '--retry-delay', '2',
         "https://api.telegram.org/bot#{token}/#{method}"] + args
  out = ''
  IO.popen(cmd, 'rb', err: %i[child out]) { |io| out = io.read.to_s }
  out.force_encoding('UTF-8')
  JSON.parse(out)
rescue JSON::ParserError
  log("ответ Telegram не разобран (#{out.bytesize} б): #{out[0, 200].inspect}")
  { 'ok' => false, 'description' => 'некорректный ответ Telegram' }
rescue StandardError => e
  { 'ok' => false, 'description' => e.message }
end

# chat_id: берём сохранённый, иначе достаём из последнего сообщения боту
def chat_id
  return ENV['TG_CHAT_ID'].strip if ENV['TG_CHAT_ID'].to_s.strip != ''
  f = File.join(HOME, 'chat_id')
  return File.read(f).strip if File.exist?(f) && !File.read(f).strip.empty?
  r = api('getUpdates')
  ids = (r['result'] || []).map { |u| u.dig('message', 'chat', 'id') }.compact.uniq
  if ids.empty?
    abort("не знаю, кому слать. Напишите боту в Telegram любое сообщение (например /start) и запустите ещё раз")
  end
  File.write(f, ids.last.to_s)
  log("chat_id определён: #{ids.last}")
  ids.last.to_s
end

def fetch(url)
  2.times do
    out = IO.popen(['curl', '-sS', '-L', '-m', '40', '-A', UA, url], err: File::NULL, &:read)
    out = out.to_s.force_encoding('UTF-8')
    return out if out.size > 1500
    sleep 2
  end
  nil
end

def clean(s)
  s.to_s.gsub(/<[^>]*>/, ' ').gsub('&nbsp;', ' ').gsub('&quot;', '"')
   .gsub('&laquo;', '«').gsub('&raquo;', '»').gsub('&amp;', '&').gsub(/\s+/, ' ').strip
end

# ---------- разбор листингов ----------
def parse_ea(html, section)
  html.split('class="product-item column').drop(1).map do |ch|
    ch = ch[0, 6000]
    href = ch[/href="(\/[^"]+)"/, 1]
    art  = ch[/class="product_art"[^>]*>\s*([0-9.]+)/m, 1]
    next nil unless href && art
    img = ch[/<img src="(\/upload\/[^"]+)"/, 1]
    req = ch[/data-endrequest="(\d+)"/, 1].to_i
    pub = ch[/data-startrequest="(\d+)"/, 1].to_i      # начало приёма заявок = публикация
    { id: "e-auction.by|#{art}", platform: 'e-auction.by', section: section,
      published: pub.positive? ? Time.at(pub) : nil,
      name: clean(ch[/class="text-header">\s*([^<]*)/m, 1]),
      price: ch[/data-cur="BYN" data-value="([0-9.]+)"/, 1].to_f,
      deadline: req.positive? ? Time.at(req) : nil,
      photo: img ? 'https://e-auction.by' + img : nil,
      url: 'https://e-auction.by' + href }
  end.compact
end

def parse_ipm(html, section)
  html.split('class="c-list__item"').drop(1).map do |ch|
    ch = ch[0, 4000]
    url = ch[/href="(https:\/\/ipmtorgi\.by\/auctions\/[^"]+)"/, 1]
    next nil unless url
    d   = ch[/c-list__item-info__date"><span>[^<]*<\/span>\s*<span>\s*([^<]*)<\/span>/m, 1].to_s
    dt  = d[/(\d{2})\.(\d{2})\.(\d{4})/] ? Time.local($3.to_i, $2.to_i, $1.to_i,
            (d[/\|\s*(\d{2}):/, 1] || '0').to_i, (d[/\|\s*\d{2}:(\d{2})/, 1] || '0').to_i) : nil
    img = ch[/background-image: url\('(\/upload\/[^']+)'\)/, 1]
    { id: "ipmtorgi.by|#{url.split('/').last}", platform: 'ipmtorgi.by', section: section,
      name: clean(ch[/c-list__item-info__name">\s*([^<]*)/m, 1]),
      price: clean(ch[/Начальная цена:<\/span>\s*<span>\s*([0-9 .,]+)\s*BYN/m, 1]).gsub(/[^0-9.]/, '').to_f,
      deadline: dt, photo: img ? 'https://ipmtorgi.by' + img : nil, url: url }
  end.compact
end

# ---------- beltorgi.by ----------
# Каталог грузится скриптом. Страница раздела отдаёт content_id и cachekey (он меняется
# при каждом открытии), а карточки приходят JSON-ом из POST /assets/category.php, по 80.
# На карточке нет ни даты публикации, ни срока заявок — только обратный отсчёт.
# Поэтому срок из отсчёта — прикидка, а точные даты новых лотов берутся из самого лота.
BT = 'https://beltorgi.by'

def post_json(url, data)
  out = IO.popen(['curl', '-sS', '-m', '60', '-A', UA, '-H', 'X-Requested-With: XMLHttpRequest',
                  '-d', data, url], err: File::NULL, &:read)
  JSON.parse(out.to_s.force_encoding('UTF-8'))
rescue JSON::ParserError
  nil
end

def parse_bt(html, section)
  html.split('class="col mb-4"').drop(1).map do |ch|
    id   = ch[/card-img-top-(\d+)/, 1]
    href = ch[/<a class="text-dark" href="([^"]+)"/, 1]
    next nil unless id && href
    thumb = ch[%r{src="(/assets/images/products/\d+/small/[^"]+)"}, 1]
    title, left = ch.match(/class="clock" title="([^"]*)">(.*?)<\/div>/m).to_a.drop(1)
    left = clean(left)
    secs = { 'дн' => 86_400, 'час' => 3600, 'мин' => 60 }
           .sum { |u, k| left[/(\d+)\s*#{u}/, 1].to_i * k }
    # «До начала приёма заявок» — лот объявлен, но срок заявок ещё не виден
    est = title.to_s.include?('окончания') && secs.positive? ? Time.now + secs : nil
    { id: "beltorgi.by|#{id}", platform: 'beltorgi.by', section: section,
      name: clean(ch[/class="card-title[^"]*">(.*?)<\/a>/m, 1]),
      price: ch[/<span class="price"><span>([^<]+)/, 1].to_s.gsub(/[^\d,]/, '').tr(',', '.').to_f,
      deadline: est, photo: thumb ? BT + thumb.sub('/small/', '/big/') : nil,
      url: "#{BT}/#{href}" }
  end.compact
end

def collect_bt(section, base)
  page = fetch(base)
  cid = page && page[/name="content_id" value="(\d+)"/, 1]
  key = page && page[/name="cachekey" value="(\d+)"/, 1]
  unless cid && key
    log("не ответил: #{base}")
    return [[], false]
  end
  form = "content_id=#{cid}&cachekey=#{key}&tpl=CardTplList&view=tab&tpltable=CardTplTable" \
         '&ListWrapper=ListWrapper&filtr%5Barray%5D%5Bresult%5D=1%2C6%2C8&limit=80&sort=1&order=1'
  out = []
  ids = {}
  pages = 0
  (1..MAX_PAGES).each do |p|
    j = post_json("#{BT}/assets/category.php", form + "&page=#{p}")
    if j.nil?
      log("не ответил: #{base} (страница #{p})")
      return [out, false]
    end
    fresh = parse_bt(j['output'].to_s, section).reject { |l| ids[l[:id]] }
    break if fresh.empty?                # за последней страницей список пуст или повторяется
    fresh.each { |l| ids[l[:id]] = true }
    pages += 1
    now = Time.now
    out.concat(fresh.reject { |l| l[:deadline] && l[:deadline] < now })
    sleep 0.8
  end
  log("beltorgi.by · #{section}: #{out.size} активных, страниц #{pages}")
  [out, true]
end

# Точные даты из карточки лота: «Начало подачи заявок» служит датой публикации.
def bt_enrich(lot)
  html = fetch(lot[:url]) or return
  at = lambda do |k|
    m = html.match(/<div>#{k}<\/div>\s*<div>\s*(\d{2})\.(\d{2})\.(\d{4})\D+(\d{1,2}):(\d{2})/) or return nil
    Time.local(m[3].to_i, m[2].to_i, m[1].to_i, m[4].to_i, m[5].to_i)
  end
  lot[:deadline]  = at.('Окончание подачи заявок') || lot[:deadline]
  # в списке название бывает обрезано — берём полное из заголовка лота
  title = clean(html[/<h1[^>]*>(.*?)<\/h1>/m, 1])
  lot[:name] = title unless title.empty?
  lot[:published] = at.('Начало подачи заявок')
  sleep 0.5
end

# ---------- cpo.by (ЦПО — организатор торгов на ИПМ) ----------
# Список по дате аукциона от поздних к ранним, с архивом. Срока заявок в списке нет — для новых
# лотов берём его со страницы лота (cpo_enrich). Большинство лотов — те же, что на ИПМ: см. sig().
def parse_cpo(html, section)
  html.split('class="sales__item"').drop(1).map do |ch|
    ch = ch[0, 5000]
    slug = ch[%r{href="https://www\.cpo\.by/auctions/([^/"]+)/"}, 1] or next
    day = ch[/sales__item-title-date.*?(\d{2})\.(\d{2})\.(\d{4})/m] ? Time.local($3.to_i, $2.to_i, $1.to_i) : nil
    pr = clean(ch[/sales__item-price__bottom[^>]*>(.*?)<div class="valute_price"/m, 1])
    img = ch[/background-image: url\('(\/upload\/[^']+)'\)/, 1]
    { id: "cpo.by|#{slug}", platform: 'cpo.by', section: section, day: day,
      name: clean(ch[/sales__item-title-title">(.*?)<\/div>/m, 1]),
      price: pr.include?('BYN') ? pr[/[\d\s.,]+(?=\s*BYN)/].to_s.gsub(/[^\d.]/, '').to_f : 0.0,
      deadline: nil, photo: img ? 'https://www.cpo.by' + img : nil, url: "https://www.cpo.by/auctions/#{slug}/" }
  end.compact
end

def cpo_enrich(lot)
  html = fetch(lot[:url]) or return
  m = html.match(/Время окончания приёма заявок:<\/b>\s*<br\s*\/?>\s*(\d{2})\.(\d{2})\.(\d{4})(?:\s|&nbsp;)+(\d{1,2}):(\d{2})/)
  lot[:deadline] = Time.local(m[3].to_i, m[2].to_i, m[1].to_i, m[4].to_i, m[5].to_i) if m
  sleep 0.5
end

# ---------- konfiskat.by (РУП «Торговый дом «Восточный») ----------
# В карточке — дата аукциона. По извещениям заявки принимают до 12:00 дня, предшествующего аукциону.
def parse_kf(html, section)
  html.split('class="product-card grid-card-style"').drop(1).map do |ch|
    href = ch[/href="([^"]+)"[^>]*class="product-name"/, 1] or next
    id = href[%r{/(\d+)/\z}, 1] or next
    ds = clean(ch[/auction-date.*?<\/svg>(.*?)<\/span>/m, 1])
    day = ds =~ /(\d{2})\.(\d{2})\.(\d{4})/ && $3.to_i > 2000 ? Time.local($3.to_i, $2.to_i, $1.to_i) : nil
    img = ch[/<img src="(\/upload\/[^"]+)"/, 1]
    { id: "konfiskat.by|#{id}", platform: 'konfiskat.by', section: section, day: day,
      name: clean(ch[/class="product-name"[^>]*>(.*?)<\/a>/m, 1]),
      price: clean(ch[/product-price-new[^>]*>\s*<span>([^<]+)/m, 1]).gsub(/[^\d.]/, '').to_f,
      deadline: day ? day - 86_400 + 12 * 3600 : nil,
      photo: img ? 'https://konfiskat.by' + img : nil, url: 'https://konfiskat.by' + href }
  end.compact
end

# Один лот на двух площадках — одно уведомление. Признак — название и стартовая цена.
# На одной площадке одинаковые название и цена — это разные лоты, их не трогаем.
def sig(l)
  l[:name].to_s.downcase.tr('ё', 'е').gsub(/[^a-zа-я0-9]/, '') + '|' + l[:price].to_f.round.to_s
end

# Раздел читается ЦЕЛИКОМ, а не первой страницей.
#
# Раньше бот смотрел только первые 9–20 карточек, и это давало две ошибки.
# ИПМ-Торги сортируют не по дате публикации, а по дедлайну приёма заявок, от поздних
# к ранним. Когда лоты сверху снимают с торгов, список сдвигается, и давно выставленный
# лот въезжает на первую страницу — бот видел его впервые и слал как «новый».
# И наоборот: свежий лот с коротким сроком заявок сразу ложится на вторую-третью
# страницу, и бот не замечал его вовсе.
MAX_PAGES = 40

def collect_section(platform, section, base)
  return collect_bt(section, base) if platform == 'beltorgi.by'

  out = []
  ids = {}
  pages = 0
  (1..MAX_PAGES).each do |p|
    url = p == 1 ? base : "#{base}?PAGEN_1=#{p}"
    html = fetch(url)
    if html.nil?
      log("не ответил: #{url}")
      return [out, false]                  # раздел прочитан не полностью
    end
    got = case platform
          when 'e-auction.by' then parse_ea(html, section)
          when 'cpo.by'       then parse_cpo(html, section)
          when 'konfiskat.by' then parse_kf(html, section)
          else parse_ipm(html, section)
          end
    break if got.empty?
    fresh = got.reject { |l| ids[l[:id]] }
    break if fresh.empty?                  # e-auction за последней страницей повторяет её же
    fresh.each { |l| ids[l[:id]] = true }
    pages += 1
    now = Time.now
    today = Time.local(now.year, now.month, now.day)
    out.concat(fresh.reject { |l| (l[:deadline] && l[:deadline] < now) || (l[:day] && l[:day] < today) ||
                                  (platform == 'konfiskat.by' && l[:deadline].nil?) })
    # ИПМ-Торги отдают и архив до 2019 года; раз список по убыванию дедлайна,
    # после первой страницы с уже закрытыми лотами активных дальше не будет
    if platform == 'ipmtorgi.by'
      oldest = got.map { |l| l[:deadline] }.compact.min
      break if oldest && oldest < now
    end
    # ЦПО — так же, по дате аукциона
    if platform == 'cpo.by'
      oldest = got.map { |l| l[:day] }.compact.min
      break if oldest && oldest < today
    end
    sleep 0.8
  end
  log("#{platform} · #{section}: #{out.size} активных, страниц #{pages}")
  [out, true]
end

def collect
  lots = []
  complete = true
  SECTIONS.each do |platform, section, url|
    # konfiskat.by закрывает доступ при частых запросах; сроки там на дни вперёд — хватит раз в час
    next if platform == 'konfiskat.by' && Time.now.min >= 15 && ENV['FORCE_ALL'].to_s.empty?
    got, ok = collect_section(platform, section, url)
    complete &&= ok
    lots.concat(got)
    sleep 1
  end
  [lots, complete]
end

# ---------- отправка ----------
def money(n)
  return 'цена не указана' if n.to_f <= 0
  "#{n.round.to_s.reverse.scan(/\d{1,3}/).join(' ').reverse} BYN"
end

# Telegram разбирает подпись как HTML — угловые скобки и & в названии нужно экранировать
def html_esc(s)
  s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
end

def send_lot(lot, cid)
  name = lot[:name].to_s
  name = name[0, 300].sub(/\s\S*\z/, '') + '…' if name.size > 300   # подпись к фото — не длиннее 1024 знаков
  caption = "#{html_esc(name)}\n\n" \
            "<b>#{money(lot[:price])}</b>\n" \
            "Заявки до #{lot[:deadline] ? lot[:deadline].strftime('%d.%m.%Y %H:%M') : '—'}\n" \
            "<a href=\"#{lot[:url]}\">#{lot[:platform]} · #{lot[:section]}</a>"
  if lot[:photo]
    File.delete(TMPIMG) if File.exist?(TMPIMG)
    system('curl', '-sS', '-L', '-m', '40', '-A', UA, '-o', TMPIMG, lot[:photo],
           out: File::NULL, err: File::NULL)
  end
  # --form-string, а не -F: значение подписи начинается с "<b>", а curl считает
  # начальные "<" и "@" ссылкой на файл и пытается его открыть.
  r = if lot[:photo] && File.exist?(TMPIMG) && File.size(TMPIMG) > 1000
        api('sendPhoto', ['--form-string', "chat_id=#{cid}", '-F', "photo=@#{TMPIMG}",
                          '--form-string', "caption=#{caption}",
                          '--form-string', 'parse_mode=HTML'])
      else
        api('sendMessage', ['--form-string', "chat_id=#{cid}", '--form-string', "text=#{caption}",
                            '--form-string', 'parse_mode=HTML'])
      end
  # если фото не приняли — пробуем хотя бы текстом, чтобы лот не потерялся
  unless r['ok']
    log("фото не ушло (#{r['description']}), пробую текстом: #{lot[:name][0, 40]}")
    r = api('sendMessage', ['--form-string', "chat_id=#{cid}", '--form-string', "text=#{caption}",
                            '--form-string', 'parse_mode=HTML'])
  end
  log("не отправлено (#{r['description']}): #{lot[:name][0, 40]}") unless r['ok']
  r['ok']
end

# ---------- запуск ----------
if File.exist?(LOCK) && (Time.now - File.mtime(LOCK)) < 600
  log('предыдущий запуск ещё идёт — выхожу')
  exit 0
end
File.write(LOCK, Process.pid.to_s)

begin
  mode = ARGV[0]

  if mode == '--test'
    me = api('getMe')
    abort("Telegram не принял токен: #{me['description']}") unless me['ok']
    cid = chat_id
    api('sendMessage', ['--form-string', "chat_id=#{cid}",
                        '--form-string', 'text=Сторож торгов на связи. Слежу за недвижимостью и транспортом.'])
    log("связь есть: @#{me.dig('result', 'username')}, chat_id #{cid}")
    exit 0
  end

  seen = File.exist?(SEEN) ? JSON.parse(File.read(SEEN)) : {}
  lots, complete = collect
  abort('ни одна площадка не ответила') if lots.empty?
  log('часть разделов прочитана не полностью — отправлю только то, что увидел') unless complete

  if mode == '--dry'
    lots.first(6).each do |l|
      puts "— #{money(l[:price])} | заявки до #{l[:deadline] ? l[:deadline].strftime('%d.%m.%Y %H:%M') : 'НЕТ'}"
      puts "  фото: #{l[:photo] ? 'есть' : 'НЕТ'}  #{l[:section]}  #{l[:name][0, 46]}"
    end
    bad = lots.count { |l| l[:deadline].nil? } + lots.count { |l| l[:photo].nil? } + lots.count { |l| l[:price].to_f <= 0 }
    puts "всего #{lots.size}; без даты #{lots.count { |l| l[:deadline].nil? }}, " \
         "без фото #{lots.count { |l| l[:photo].nil? }}, без цены #{lots.count { |l| l[:price].to_f <= 0 }}"
    exit(bad.zero? ? 0 : 0)
  end

fresh = lots.reject { |l| seen.key?(l[:id]) }

# Дубли: такой же лот (название + цена) уже встречался на другой площадке — не шлём.
# И внутри прогона: ИПМ и ЦПО выставили лот одновременно — оставляем ИПМ.
known = Hash.new { |h, k| h[k] = [] }
seen.each_key { |k| next unless k.start_with?('sig|'); _, p, sg = k.split('|', 3); known[sg] << p }
fresh = fresh.each_with_index.sort_by { |l, i| [l[:platform] == 'cpo.by' ? 1 : 0, i] }.map(&:first)
firsts = {}
dups, fresh = fresh.partition do |l|
  sg = sig(l)
  hit = (known[sg] - [l[:platform]]).any? || (firsts[sg] && firsts[sg] != l[:platform])
  firsts[sg] ||= l[:platform]
  hit
end
dups.each { |l| seen[l[:id]] = Time.now.to_i }
log("дублей с других площадок пропущено: #{dups.size}") unless dups.empty?

# beltorgi: заходим в каждый новый лот за точным сроком и датой публикации.
# При --init это не нужно, а предел защищает от сотни запросов разом.
unless mode == '--init'
  bt = fresh.select { |l| l[:platform] == 'beltorgi.by' }
  log("beltorgi: новых #{bt.size}, уточняю первые #{MAX_SEND * 2}") if bt.size > MAX_SEND * 2
  bt.first(MAX_SEND * 2).each { |l| bt_enrich(l) }
  fresh.select { |l| l[:platform] == 'cpo.by' }.first(MAX_SEND * 2).each { |l| cpo_enrich(l) }
end

  # Второй предохранитель: e-auction отдаёт дату публикации. Лот, выставленный
  # больше FRESH_DAYS назад, — не новость, даже если бот его раньше не встречал.
  # Такой лот молча запоминаем и не шлём.
  stale_cut = Time.now - FRESH_DAYS * 86_400
  stale, fresh = fresh.partition { |l| l[:published] && l[:published] < stale_cut }
  stale.each { |l| seen[l[:id]] = Time.now.to_i }
  log("получено #{lots.size}, новых #{fresh.size}" +
      (stale.empty? ? '' : ", давно выставленных и пропущенных #{stale.size}"))

  if mode == '--init'
    lots.each { |l| seen[l[:id]] = Time.now.to_i }
    lots.each { |l| seen["sig|#{l[:platform]}|#{sig(l)}"] = Time.now.to_i }
    File.write(SEEN, JSON.generate(seen))
    log("инициализация: запомнил #{lots.size} лотов, ничего не отправлял")
    exit 0
  end

  if fresh.size > MAX_SEND
    log("новых #{fresh.size} — это больше предохранителя #{MAX_SEND}; отправлю #{MAX_SEND}, остальные помечу прочитанными")
  end

  # Счётчик неудач: лот, который не удалось отправить, пробуем ещё дважды
  # в следующих циклах, а не теряем молча.
  fails_path = File.join(HOME, 'fails.json')
  fails = File.exist?(fails_path) ? JSON.parse(File.read(fails_path)) : {}

  cid = chat_id
  sent = 0
  fresh.sort_by { |l| l[:deadline] || Time.now }.each do |l|
    if sent >= MAX_SEND
      seen[l[:id]] = Time.now.to_i        # осознанно пропускаем: сработал предохранитель
      next
    end
    if send_lot(l, cid)
      sent += 1
      seen[l[:id]] = Time.now.to_i
      fails.delete(l[:id])
    else
      fails[l[:id]] = fails[l[:id]].to_i + 1
      if fails[l[:id]] >= 3
        log("сдаюсь после 3 попыток: #{l[:name][0, 50]}")
        seen[l[:id]] = Time.now.to_i
        fails.delete(l[:id])
      end
    end
    sleep 1.2
  end
  File.write(fails_path, JSON.generate(fails))

  # чистим память старше 120 дней, чтобы файл не рос вечно
  # подписи всех видимых лотов — чтобы завтрашняя копия на другой площадке узналась как дубль
  lots.each { |l| seen["sig|#{l[:platform]}|#{sig(l)}"] = Time.now.to_i }
  cutoff = Time.now.to_i - 120 * 86_400
  seen.reject! { |_, t| t.to_i < cutoff }
  File.write(SEEN, JSON.generate(seen))
  log("отправлено #{sent}, в памяти #{seen.size}")
ensure
  File.delete(LOCK) if File.exist?(LOCK)
end
