// lib/main.dart
import 'dart:io';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final databasesPath = await getDatabasesPath();
  final path = p.join(databasesPath, 'estoque.db');

  final database = await openDatabase(
    path,
    version: 1,
    onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE usuarios (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nome TEXT NOT NULL,
          usuario TEXT UNIQUE NOT NULL,
          senha TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE produtos (
          codigo TEXT PRIMARY KEY,
          nome TEXT NOT NULL,
          quantidade INTEGER NOT NULL,
          preco REAL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE movimentacoes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          codigo TEXT,
          nome TEXT,
          quantidade INTEGER,
          tipo TEXT,
          usuario TEXT,
          data_hora TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE vendas (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          usuario TEXT,
          total REAL,
          data_hora TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE venda_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          venda_id INTEGER,
          codigo TEXT,
          nome TEXT,
          quantidade INTEGER,
          preco_unitario REAL,
          subtotal REAL
        )
      ''');
    },
    onOpen: (db) async {
      final info = await db.rawQuery("PRAGMA table_info(produtos)");
      final hasPreco = info.any((row) => (row['name'] as String).toLowerCase() == 'preco');
      if (!hasPreco) {
        try {
          await db.execute("ALTER TABLE produtos ADD COLUMN preco REAL DEFAULT 0");
        } catch (_) {}
      }
      await db.execute('''CREATE TABLE IF NOT EXISTS vendas (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            usuario TEXT,
            total REAL,
            data_hora TEXT
          )''');
      await db.execute('''CREATE TABLE IF NOT EXISTS venda_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            venda_id INTEGER,
            codigo TEXT,
            nome TEXT,
            quantidade INTEGER,
            preco_unitario REAL,
            subtotal REAL
          )''');
    },
  );

  final admins = await database.query('usuarios', where: 'usuario = ?', whereArgs: ['admin']);
  if (admins.isEmpty) {
    await database.insert('usuarios', {'nome': 'Administrador', 'usuario': 'admin', 'senha': 'freire123'});
  }

  runApp(MyApp(database: database));
}

class MyApp extends StatelessWidget {
  final Database database;
  const MyApp({super.key, required this.database});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Freire & Freitas Padaria',
      theme: ThemeData(primarySwatch: Colors.amber, useMaterial3: true),
      home: LoginPage(database: database),
      debugShowCheckedModeBanner: false,
    );
  }
}

/* LOGIN PAGE */
class LoginPage extends StatefulWidget {
  final Database database;
  const LoginPage({super.key, required this.database});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;

  Future<void> _login() async {
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text.trim();
    if (user.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Preencha usuário e senha')));
      return;
    }
    setState(() => _loading = true);
    final res = await widget.database.query(
      'usuarios',
      columns: ['nome', 'usuario'],
      where: 'usuario = ? AND senha = ?',
      whereArgs: [user, pass],
    );
    setState(() => _loading = false);
    if (res.isNotEmpty) {
      final nome = res.first['nome'] as String;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => HomePage(database: widget.database, usuarioNome: nome, usuarioLogin: user),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Usuário ou senha incorretos')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login - Controle de Estoque')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(children: [
          TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: 'Usuário')),
          const SizedBox(height: 8),
          TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: 'Senha'), obscureText: true),
          const SizedBox(height: 16),
          ElevatedButton.icon(onPressed: _loading ? null : _login, icon: const Icon(Icons.login), label: _loading ? const Text('Entrando...') : const Text('Entrar')),
          const SizedBox(height: 12),
          const Text('Usuário padrão: admin | Senha: freire123', style: TextStyle(color: Colors.grey)),
        ]),
      ),
    );
  }
}

/* HOME / VENDAS */
class HomePage extends StatefulWidget {
  final Database database;
  final String usuarioNome;
  final String usuarioLogin;
  const HomePage({super.key, required this.database, required this.usuarioNome, required this.usuarioLogin});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _codigoCtrl = TextEditingController();
  final _nomeCtrl = TextEditingController();
  final _qtdCtrl = TextEditingController();
  final _precoCtrl = TextEditingController();
  final _pesquisaCtrl = TextEditingController();

  List<Map<String, Object?>> produtos = [];
  List<CartItem> cart = [];

  @override
  void initState() {
    super.initState();
    _refreshLista();
  }

  Future<void> _refreshLista([String filtro = '']) async {
    final db = widget.database;
    List<Map<String, Object?>> rows;
    if (filtro.isNotEmpty) {
      rows = await db.query('produtos', where: 'nome LIKE ? OR codigo LIKE ?', whereArgs: ['%$filtro%', '%$filtro%'], orderBy: 'nome');
    } else {
      rows = await db.query('produtos', orderBy: 'nome');
    }
    setState(() => produtos = rows);
  }

  Future<void> _buscarNomePorCodigo(String codigo) async {
    if (codigo.isEmpty) return;
    final res = await widget.database.query('produtos', columns: ['nome','preco'], where: 'codigo = ?', whereArgs: [codigo]);
    if (res.isNotEmpty) {
      _nomeCtrl.text = res.first['nome'] as String;
      _precoCtrl.text = (res.first['preco'] ?? 0).toString();
    } else {
      _nomeCtrl.clear();
      _precoCtrl.clear();
    }
  }

  Future<void> _salvarProduto() async {
    final codigo = _codigoCtrl.text.trim();
    final nome = _nomeCtrl.text.trim();
    final qtd = int.tryParse(_qtdCtrl.text.trim()) ?? 0;
    final preco = double.tryParse(_precoCtrl.text.trim().replaceAll(',', '.')) ?? 0.0;
    if (codigo.isEmpty || nome.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Código e nome são obrigatórios')));
      return;
    }
    final db = widget.database;
    final exists = await db.query('produtos', where: 'codigo = ?', whereArgs: [codigo]);
    if (exists.isNotEmpty) {
      await db.update('produtos', {'nome': nome, 'quantidade': qtd, 'preco': preco}, where: 'codigo = ?', whereArgs: [codigo]);
    } else {
      await db.insert('produtos', {'codigo': codigo, 'nome': nome, 'quantidade': qtd, 'preco': preco});
    }
    await _refreshLista();
    _codigoCtrl.clear();
    _nomeCtrl.clear();
    _qtdCtrl.clear();
    _precoCtrl.clear();
  }

  Future<void> _addToCartByCode(String codigo, {int qty = 1}) async {
    if (codigo.isEmpty) return;
    final res = await widget.database.query('produtos', where: 'codigo = ?', whereArgs: [codigo]);
    if (res.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Produto não cadastrado')));
      return;
    }
    final prod = res.first;
    final existing = cart.indexWhere((c) => c.codigo == prod['codigo']);
    if (existing >= 0) {
      cart[existing] = cart[existing].copyWith(quantidade: cart[existing].quantidade + qty);
    } else {
      cart.add(CartItem(codigo: prod['codigo'] as String, nome: prod['nome'] as String, quantidade: qty, precoUnitario: (prod['preco'] ?? 0) as double));
    }
    setState(() {});
  }

  double get cartTotal => cart.fold(0.0, (t, c) => t + c.subtotal);

  Future<void> _finalizarVenda() async {
    if (cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Carrinho vazio')));
      return;
    }
    final db = widget.database;
    final now = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final total = cartTotal;
    final vendaId = await db.insert('vendas', {'usuario': widget.usuarioNome, 'total': total, 'data_hora': now});
    for (final item in cart) {
      await db.insert('venda_items', {
        'venda_id': vendaId,
        'codigo': item.codigo,
        'nome': item.nome,
        'quantidade': item.quantidade,
        'preco_unitario': item.precoUnitario,
        'subtotal': item.subtotal,
      });
      final prod = await db.query('produtos', where: 'codigo = ?', whereArgs: [item.codigo]);
      if (prod.isNotEmpty) {
        final atual = prod.first['quantidade'] as int;
        final novo = (atual - item.quantidade).clamp(0, 999999);
        await db.update('produtos', {'quantidade': novo}, where: 'codigo = ?', whereArgs: [item.codigo]);
        await db.insert('movimentacoes', {'codigo': item.codigo, 'nome': item.nome, 'quantidade': item.quantidade, 'tipo': 'venda', 'usuario': widget.usuarioNome, 'data_hora': now});
      }
    }
    cart.clear();
    await _refreshLista();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Venda finalizada ✅  Total: R\$ ${total.toStringAsFixed(2)}')));
  }

  Future<void> _abrirScanner() async {
    final codigo = await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScannerPage()));
    if (codigo != null && codigo is String) {
      await _addToCartByCode(codigo, qty: 1);
    }
  }

  Future<void> _abrirCarrinho() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(builder: (context, setModalState) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.75,
            child: Column(children: [
              AppBar(title: const Text('Carrinho'), automaticallyImplyLeading: false, actions: [
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context))
              ]),
              Expanded(
                child: ListView.builder(
                  itemCount: cart.length,
                  itemBuilder: (_, i) {
                    final it = cart[i];
                    return ListTile(
                      title: Text(it.nome),
                      subtitle: Text('Qtd: ${it.quantidade}  •  R\$ ${it.precoUnitario.toStringAsFixed(2)}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.remove), onPressed: () {
                          if (it.quantidade > 1) {
                            setModalState(() {
                              cart[i] = it.copyWith(quantidade: it.quantidade - 1);
                            });
                            setState(() {});
                          }
                        }),
                        Text(it.quantidade.toString()),
                        IconButton(icon: const Icon(Icons.add), onPressed: () {
                          setModalState(() {
                            cart[i] = it.copyWith(quantidade: it.quantidade + 1);
                          });
                          setState(() {});
                        }),
                        IconButton(icon: const Icon(Icons.delete), onPressed: () {
                          setModalState(() {
                            cart.removeAt(i);
                          });
                          setState(() {});
                        }),
                      ]),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Text('Total:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('R\$ ${cartTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Continuar'))),
                    const SizedBox(width: 8),
                    ElevatedButton(onPressed: () async {
                      Navigator.pop(context);
                      await _finalizarVenda();
                    }, child: const Text('Finalizar Venda')),
                  ])
                ]),
              )
            ]),
          ),
        );
      }),
    );
  }

  Future<void> _abrirHistorico() async {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => HistoricoPage(database: widget.database)));
  }

  Future<void> _gerenciarUsuarios() async {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => GerenciarUsuariosPage(database: widget.database)));
  }

  Future<void> _exportarRelatorio() async {
    final db = widget.database;
    final produtosDb = await db.query('produtos');
    final excel = Excel.createExcel();
    final sheet = excel['Planilha1'];
    sheet.appendRow(['Código', 'Nome', 'Quantidade', 'Preço']);
    for (var p in produtosDb) {
      sheet.appendRow([p['codigo'], p['nome'], p['quantidade'], p['preco']]);
    }
    final bytes = excel.encode();
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Erro ao gerar Excel')));
      return;
    }
    Directory? downloads;
    if (Platform.isAndroid) {
      downloads = Directory('/storage/emulated/0/Download');
    } else {
      downloads = await getApplicationDocumentsDirectory();
    }
    final fileName = 'relatorio_estoque_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
    final file = File(p.join(downloads!.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Relatório salvo: ${file.path}')));
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.usuarioLogin == 'admin';
    return Scaffold(
      appBar: AppBar(
        title: Text('Freire & Freitas - ${widget.usuarioNome}'),
        actions: [
          IconButton(onPressed: _abrirHistorico, icon: const Icon(Icons.history), tooltip: 'Histórico'),
          IconButton(onPressed: _exportarRelatorio, icon: const Icon(Icons.file_download), tooltip: 'Exportar'),
          IconButton(onPressed: _abrirCarrinho, icon: Stack(children: [
            const Icon(Icons.shopping_cart),
            if (cart.isNotEmpty) Positioned(right: 0, child: CircleAvatar(radius: 8, backgroundColor: Colors.red, child: Text(cart.length.toString(), style: const TextStyle(fontSize: 10, color: Colors.white)))),
          ])),
          if (isAdmin) IconButton(onPressed: _gerenciarUsuarios, icon: const Icon(Icons.admin_panel_settings), tooltip: 'Usuários'),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(children: [
          Row(children: [
            Expanded(flex: 3, child: TextField(controller: _codigoCtrl, decoration: const InputDecoration(labelText: 'Código de Barras'), onSubmitted: (v) => _buscarNomePorCodigo(v))),
            const SizedBox(width: 8),
            ElevatedButton.icon(onPressed: _abrirScanner, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan')),
            const SizedBox(width: 8),
            ElevatedButton.icon(onPressed: () {
              final code = _codigoCtrl.text.trim();
              if (code.isNotEmpty) _addToCartByCode(code, qty: 1);
            }, icon: const Icon(Icons.add_shopping_cart), label: const Text('Adicionar')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _nomeCtrl, decoration: const InputDecoration(labelText: 'Nome do Produto'))),
            const SizedBox(width: 8),
            SizedBox(width: 100, child: TextField(controller: _qtdCtrl, decoration: const InputDecoration(labelText: 'Quantidade'), keyboardType: TextInputType.number)),
            const SizedBox(width: 8),
            SizedBox(width: 120, child: TextField(controller: _precoCtrl, decoration: const InputDecoration(labelText: 'Preço (R\$)'), keyboardType: TextInputType.number)),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _salvarProduto, child: const Text('Salvar Produto')),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _pesquisaCtrl, decoration: const InputDecoration(labelText: 'Pesquisar (nome ou código)'), onChanged: (v) => _refreshLista(v)),
          const SizedBox(height: 12),
          Expanded(child: ListView.builder(itemCount: produtos.length, itemBuilder: (_, i) {
            final p = produtos[i];
            return ListTile(
              title: Text('${p['nome']}'),
              subtitle: Text('Código: ${p['codigo']}  •  Qtd: ${p['quantidade']}  •  R\$ ${(p['preco'] ?? 0).toStringAsFixed(2)}'),
              onTap: () {
                _codigoCtrl.text = p['codigo'] as String;
                _nomeCtrl.text = p['nome'] as String;
                _qtdCtrl.text = (p['quantidade'] as int).toString();
                _precoCtrl.text = (p['preco'] ?? 0).toString();
                FocusScope.of(context).requestFocus(FocusNode());
              },
              trailing: IconButton(icon: const Icon(Icons.add_shopping_cart), onPressed: () {
                _addToCartByCode(p['codigo'] as String, qty: 1);
              }),
            );
          })),
        ]),
      ),
    );
  }
}

class CartItem {
  final String codigo;
  final String nome;
  final int quantidade;
  final double precoUnitario;
  CartItem({required this.codigo, required this.nome, required this.quantidade, required this.precoUnitario});
  double get subtotal => quantidade * precoUnitario;
  CartItem copyWith({int? quantidade}) => CartItem(codigo: codigo, nome: nome, quantidade: quantidade ?? this.quantidade, precoUnitario: precoUnitario);
}

/* Scanner, Historico, GerenciarUsuarios same as previous versions (omitted for brevity) */
class ScannerPage extends StatelessWidget {
  ScannerPage({super.key});
  final MobileScannerController cameraController = MobileScannerController();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner')),
      body: MobileScanner(
        controller: cameraController,
        allowDuplicates: false,
        onDetect: (barcode, args) {
          final code = barcode.rawValue ?? '';
          if (code.isNotEmpty) {
            Navigator.of(context).pop(code);
          }
        },
      ),
    );
  }
}

class HistoricoPage extends StatelessWidget {
  final Database database;
  const HistoricoPage({super.key, required this.database});
  Future<List<Map<String, Object?>>> _load() async => await database.query('movimentacoes', orderBy: 'id DESC');
  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('Histórico')), body: FutureBuilder(future: _load(), builder: (context, snap) { if (!snap.hasData) return const Center(child: CircularProgressIndicator()); final rows = snap.data! as List; return ListView.builder(itemCount: rows.length, itemBuilder: (_, i) { final r = rows[i]; return ListTile(title: Text('${r['tipo']} - ${r['nome']} (${r['quantidade']})'), subtitle: Text('Usuário: ${r['usuario']} • ${r['data_hora']}')); }); })); }
class GerenciarUsuariosPage extends StatefulWidget { final Database database; const GerenciarUsuariosPage({super.key, required this.database}); @override State<GerenciarUsuariosPage> createState() => _GerenciarUsuariosPageState(); }
class _GerenciarUsuariosPageState extends State<GerenciarUsuariosPage> {
  List<Map<String, Object?>> usuarios = [];
  final nomeCtrl = TextEditingController();
  final usuarioCtrl = TextEditingController();
  final senhaCtrl = TextEditingController();
  @override void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async { final res = await widget.database.query('usuarios', orderBy: 'nome'); setState(() => usuarios = res); }
  Future<void> _add() async { final nome = nomeCtrl.text.trim(); final usuario = usuarioCtrl.text.trim(); final senha = senhaCtrl.text.trim(); if (nome.isEmpty || usuario.isEmpty || senha.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Preencha todos os campos'))); return; } try { await widget.database.insert('usuarios', {'nome': nome, 'usuario': usuario, 'senha': senha}); nomeCtrl.clear(); usuarioCtrl.clear(); senhaCtrl.clear(); await _refresh(); } catch (e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Erro: usuário já existe'))); } }
  Future<void> _del(int id, String username) async { if (username == 'admin') { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não é possível excluir admin'))); return; } await widget.database.delete('usuarios', where: 'id = ?', whereArgs: [id]); await _refresh(); }
  @override Widget build(BuildContext context) { return Scaffold(appBar: AppBar(title: const Text('Gerenciar Usuários')), body: Padding(padding: const EdgeInsets.all(12), child: Column(children: [ TextField(controller: nomeCtrl, decoration: const InputDecoration(labelText: 'Nome')), TextField(controller: usuarioCtrl, decoration: const InputDecoration(labelText: 'Usuário')), TextField(controller: senhaCtrl, decoration: const InputDecoration(labelText: 'Senha'), obscureText: true), ElevatedButton(onPressed: _add, child: const Text('Adicionar usuário')), const SizedBox(height: 10), Expanded(child: ListView.builder(itemCount: usuarios.length, itemBuilder: (_, i) { final u = usuarios[i]; return ListTile(title: Text('${u['nome']} (${u['usuario']})'), trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => _del(u['id'] as int, u['usuario'] as String))); })), ]))); }
