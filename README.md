# KipuBank - Smart Contract Bancario

**Autor:** maugust
**Contacto:** https://github.com/maugust17
**Propósito:** TP2 de ETHKipu - Proyecto educacional

⚠️ **IMPORTANTE: No usar en producción**

## Descripción

KipuBank es un smart contract bancario simple desarrollado en Solidity que permite a los usuarios crear cuentas, depositar y retirar Ether de forma segura. El contrato incluye protecciones contra ataques de reentrancy y límites de transacción.

## Funcionalidades Principales

### 🏦 Gestión de Cuentas
- **Crear cuenta**: Los usuarios pueden registrarse con nombre y email
- **Balance personal**: Consulta del saldo individual de cada cuenta
- **Verificación de existencia**: Solo cuentas registradas pueden operar

### 💰 Operaciones Financieras
- **Depósitos**: Agregar Ether a la cuenta propia
- **Retiros**: Extraer Ether de la cuenta (con límites de seguridad)
- **Balance del banco**: Solo el propietario puede ver el saldo total

### 🔒 Características de Seguridad
- **Protección contra reentrancy**: Previene ataques de reentrada
- **Límite de retiro**: Máximo 0.1 ETH por transacción
- **Capacidad del banco**: Límite total de 10 ETH en el contrato
- **Control de propietario**: Funciones administrativas restringidas

## Cómo Interactuar con el Contrato

### 1. Despliegue
```solidity
// En Remix IDE, compilar y desplegar con un valor de _bankCap
constructor(uint256 _bankCap, uint256 _maxWithdrawAmount)
```

### 2. Crear una Cuenta
```solidity
// Llamar función con ETH opcional para depósito inicial
createAccount("tu@email.com", "Tu Nombre")
```

### 3. Depositar ETH
```solidity
// Enviar ETH junto con la llamada
depositIntoMyAccount()
```

### 4. Consultar Balance
```solidity
// Solo el dueño de la cuenta puede ver su balance
getAccountBalance()
```

### 5. Retirar ETH
```solidity
// Especificar cantidad en Wei (máximo 0.1 ETH = 100000000000000000 Wei)
withdraw(100000000000000000)
```

### 6. Funciones de Propietario
```solidity
// Solo el propietario del contrato puede llamar:
getTotalBankBalance()
```

## Límites y Restricciones

| Límite | Valor |
|--------|-------|
| Retiro máximo por transacción | 0.1 ETH |
| Capacidad total del banco | 10 ETH |
| Cuentas por dirección | 1 cuenta única |

## Eventos

El contrato emite los siguientes eventos:

- `Bank_Deposit(address origin, uint256 valor)`: Cuando se realiza un depósito
- `Bank_Withdraw(address destination, uint256 valor)`: Cuando se realiza un retiro

## Errores Personalizados

- `Bank_DifferentOwner()`: Acceso denegado a funciones de propietario
- `Bank_TransferError()`: Error en transferencia de ETH
- `Bank_AccountAlreadyExists()`: Cuenta ya existe para esta dirección
- `Bank_AccountNotExists()`: Cuenta no existe
- `Bank_InsuficientFunds()`: Saldo insuficiente
- `Bank_ExceedWithdrawAmount()`: Excede límite de retiro
- `Bank_ExceedBankCap()`: Excede capacidad del banco
- `Bank_NoReentrancy()`: Intento de ataque de reentrancy

## Estadísticas

El contrato mantiene contadores públicos de:
- `s_depositCounter`: Número total de depósitos realizados
- `s_withdrawCounter`: Número total de retiros realizados

## Desarrollo

### Entorno
- **IDE:** Remix (remix.ethereum.org)
- **Solidity:** ^0.8.30
- **Licencia:** MIT

### Estructura del Proyecto
```
├── contracts/
│   └── 1_Kipubank.sol    # Contrato principal
├── artifacts/            # Artefactos compilados
└── .deps/               # Dependencias de Remix
```

### Comandos Útiles en Remix
1. **Compilar**: Ctrl+S o botón "Compile"
2. **Desplegar**: Pestaña "Deploy & Run Transactions"
3. **Interactuar**: Usar la interfaz generada después del despliegue
4. **Debug**: Usar el debugger integrado de Remix

## Flujo de Uso Típico

1. **Desplegar el contrato** especificando la capacidad máxima y el límite máximo para retiro
2. **Crear cuenta personal** con `createAccount()`
3. **Depositar ETH** usando `depositIntoMyAccount()` con value
4. **Verificar balance** con `getAccountBalance()`
5. **Retirar ETH** usando `withdraw()` (respetando límites)
6. **Monitorear eventos** para confirmar transacciones

## Consideraciones de Gas

- Creación de cuenta: ~100,000 gas
- Depósito: ~50,000 gas
- Retiro: ~60,000 gas
- Consultas: ~30,000 gas

---

**Nota:** Este contrato está diseñado únicamente con fines educativos. No utilizar con fondos reales en producción.