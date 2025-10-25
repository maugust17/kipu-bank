// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*///////////////////////
        Imports
///////////////////////*/
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*///////////////////////
        Libraries
///////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*///////////////////////
        Interfaces
///////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts@1.4.0/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author maugust
 * @notice Contrato de banco descentralizado multi-token con soporte para ETH y USDC
 * @dev No usar en producción - TP3 de ETHKipu
 * @dev Utiliza OpenZeppelin para seguridad y Chainlink para conversión de precios
 * @custom:contact https://github.com/maugust17
 */
contract KipuBank is Ownable {
    /*///////////////////////
        TYPE DECLARATIONS
    ///////////////////////*/

    using SafeERC20 for IERC20;

    /*///////////////////////
           VARIABLES
    ///////////////////////*/

    /**
     * @notice Estructura que representa una cuenta bancaria
     * @dev Almacena la información de cada usuario del banco por token
     * @param balance Saldo actual de la cuenta en wei o unidades del token
     * @param name Nombre del titular de la cuenta
     * @param email Correo electrónico del titular
     * @param exists Indicador booleano que determina si la cuenta ha sido creada
     */
    struct Account {
        uint256 balance;
        string name;
        string email;
        bool exists;
    }

    /**
     * @notice Mapeo anidado para almacenar cuentas bancarias por usuario y token
     * @dev Primer nivel: dirección del usuario, Segundo nivel: dirección del token
     *      address(0) representa ETH nativo, otras direcciones representan tokens ERC20
     */
    mapping(address user => mapping(address token => Account)) private s_vault;

    /**
     * @notice Cerrojo de seguridad para prevenir ataques de reentrada
     * @dev Variable booleana utilizada como semáforo de exclusión mutua en el modificador noRentrancy
     */
    bool private s_locked;

    /**
     * @notice Monto máximo permitido por transacción de retiro
     * @dev Límite inmutable establecido en el constructor para controlar retiros individuales
     *      Aplica tanto para ETH como para USDC
     */
    uint256 public immutable i_maxWithdrawAmount;

    /**
     * @notice Capacidad máxima total que puede almacenar el banco por usuario y token
     * @dev Límite inmutable del balance establecido en el constructor
     *      Se verifica en los modificadores exceedBankCapp y exceedBankCappUSDC
     */
    uint256 public immutable i_bankCap;

    /**
     * @notice Interfaz inmutable para interactuar con el token USDC
     * @dev Almacena la dirección del contrato USDC, establecida en el constructor
     *      Utilizada para transferencias seguras mediante SafeERC20
     */
    IERC20 immutable i_usdc;

    /**
     * @notice Contador del número total de depósitos realizados
     * @dev Se incrementa cada vez que se ejecuta exitosamente un depósito de ETH o USDC
     */
    uint256 public s_depositCounter;

    /**
     * @notice Contador del número total de retiros realizados
     * @dev Se incrementa cada vez que se ejecuta exitosamente un retiro de ETH o USDC
     */
    uint256 public s_withdrawCounter;

    /**
     * @notice Constante que define el intervalo máximo de actualización del oráculo (heartbeat)
     * @dev Valor de 3600 segundos (1 hora) para validar la frescura de datos de Chainlink
     *      Si han pasado más segundos desde la última actualización, el precio se considera obsoleto
     */
    uint256 constant ORACLE_HEARTBEAT = 3600;

    /**
     * @notice Factor de conversión decimal para ajustar precisión en cálculos
     * @dev 10^20 utilizado para mantener precisión en la conversión ETH-USD
     *      Compensa la diferencia de decimales entre ETH (18) y el feed de Chainlink (8)
     */
    uint256 constant DECIMAL_FACTOR = 1 * 10 ** 20;

    /**
     * @notice Constante para evitar números mágicos en el código
     * @dev Representa cero, utilizada para mejorar legibilidad y mantener buenas prácticas
     */
    uint256 constant ZERO = 0;

    /**
     * @notice Interfaz para interactuar con el Price Feed de Chainlink ETH/USD
     * @dev Almacena la dirección del agregador de Chainlink configurada en el constructor
     * @dev Documentación: https://docs.chain.link/data-feeds/price-feeds/addresses
     */
    AggregatorV3Interface public s_feeds;

    /*///////////////////////
           EVENTS
    ///////////////////////*/

    /**
     * @notice Evento emitido cuando se completa un depósito exitosamente
     * @dev Se emite tanto en depositEther como en depositUSDC
     * @param origin Dirección que realizó el depósito
     * @param valor Cantidad depositada (wei para ETH, unidades base para USDC)
     */
    event KipuBank_Deposit(address origin, uint256 valor);

    /**
     * @notice Evento emitido cuando se completa un retiro exitosamente
     * @dev Se emite tanto en withdrawEther como en withdrawUSDC
     * @param destination Dirección que recibe el retiro
     * @param valor Cantidad retirada (wei para ETH, unidades base para USDC)
     */
    event KipuBank_Withdraw(address destination, uint256 valor);

    /**
     * @notice Evento emitido cuando se actualiza la dirección del Price Feed de Chainlink
     * @dev Permite rastrear cambios en la configuración del oráculo
     * @param feed Nueva dirección del agregador de Chainlink
     */
    event KipuBank_ChainlinkFeedUpdated(address feed);

    /*///////////////////////
           ERRORS
    ///////////////////////*/

    /**
     * @notice Error emitido cuando alguien diferente al propietario intenta ejecutar funciones restringidas
     * @dev Se lanza cuando una dirección no autorizada intenta acceder a funciones de administrador
     *      En esta versión, la verificación se maneja mediante el modificador onlyOwner de OpenZeppelin
     */
    error KipuBank_DifferentOwner();

    /**
     * @notice Error emitido cuando falla la transferencia de ether en un retiro
     * @dev Se lanza en withdrawEther si la llamada .call() retorna false
     */
    error KipuBank_TransferError();


    /**
     * @notice Error emitido cuando se intenta operar con una cuenta inexistente
     * @dev Se lanza en el modificador onlyAccountOwners si exists es false
     */
    error KipuBank_AccountNotExists();

    /**
     * @notice Error emitido cuando no hay saldo suficiente para realizar un retiro
     * @dev Se lanza en los modificadores canWithdrawEther o canWithdrawUSDC
     *      si el monto solicitado excede el balance disponible
     */
    error KipuBank_InsufficientFunds();

    /**
     * @notice Error emitido cuando se intenta retirar más del límite permitido
     * @dev Se lanza en los modificadores canWithdrawEther o canWithdrawUSDC
     *      si el monto excede i_maxWithdrawAmount
     */
    error KipuBank_ExceedWithdrawAmount();

    /**
     * @notice Error emitido cuando se intenta depositar más del límite permitido por usuario
     * @dev Se lanza en los modificadores exceedBankCapp
     *      si el balance resultante supera i_bankCap
     */
    error KipuBank_ExceedBankCap();

    /**
     * @notice Error emitido cuando se detecta un intento de ataque de reentrada
     * @dev Se lanza en el modificador noRentrancy si s_locked ya está en true
     */
    error KipuBank_NoReentrancy();

    /**
     * @notice Error emitido cuando el oráculo de Chainlink retorna datos inválidos
     * @dev Se lanza en chainlinkFeed() cuando el precio retornado es cero o negativo
     *      Indica un problema con el oráculo o configuración incorrecta
     */
    error KipuBank_OracleCompromised();

    /**
     * @notice Error emitido cuando los datos del oráculo están desactualizados
     * @dev Se lanza en chainlinkFeed() cuando la última actualización excede ORACLE_HEARTBEAT
     *      Previene el uso de precios obsoletos que podrían ser manipulados
     */
    error KipuBank_StalePrice();

    /**
     * @notice Error emitido cuando se intenta hacer un deposito sin monto
     * @dev Se lanza en deposit() cuando el monto enviado a depositar es 0
     *      Previene el incremento del contador de depositos si- no se envía un monto
     */
    error KipuBank_NothingToDeposit();

    /*///////////////////////
           Modifiers
    ///////////////////////*/

    /**
     * @notice Modificador que previene ataques de reentrada
     * @dev Utiliza el patrón de cerrojo: establece s_locked en true antes de ejecutar
     *      la función y lo libera (false) después. Revierte si ya está bloqueado
     */
    modifier noRentrancy() {
        if (s_locked) revert KipuBank_NoReentrancy();
        s_locked = true;
        _;
        s_locked = false;
    }



    /**
     * @notice Modificador que valida si una cuenta tiene saldo suficiente de ETH para retirar
     * @dev Verifica dos condiciones:
     *      1. Saldo suficiente en la cuenta de ETH (address(0))
     *      2. Monto no excede el límite de retiro i_maxWithdrawAmount
     * @param _amount Monto en wei que se desea retirar
     */
    modifier canWithdrawEther(uint256 _amount) {
        uint256 userBalance = s_vault[msg.sender][address(0)].balance;
        if (_amount > userBalance) revert KipuBank_InsufficientFunds();
        if (_amount > i_maxWithdrawAmount) revert KipuBank_ExceedWithdrawAmount();
        _;
    }

    /**
     * @notice Modificador que valida si una cuenta tiene saldo suficiente de USDC para retirar
     * @dev Verifica dos condiciones:
     *      1. Saldo suficiente en la cuenta de USDC (address(i_usdc))
     *      2. Monto no excede el límite de retiro i_maxWithdrawAmount
     * @param _amount Monto en unidades base de USDC que se desea retirar
     */
    modifier canWithdrawUSDC(uint256 _amount) {
        uint256 userBalance = s_vault[msg.sender][address(i_usdc)].balance;
        if (_amount > userBalance) revert KipuBank_InsufficientFunds();
        if (_amount > i_maxWithdrawAmount) revert KipuBank_ExceedWithdrawAmount();
        _;
    }

    /**
     * @notice Modificador que controla que no se exceda la capacidad máxima de ETH por usuario
     * @dev Verifica que el balance de ETH del usuario no supere i_bankCap después del depósito
     *      Se ejecuta antes de la función para validar el estado resultante
     *      Valida automáticamente msg.value para funciones payable
     */
    modifier exceedBankCap(uint256 _amount) {
        if (contractBalanceInUSD() + _amount > i_bankCap) {
            revert KipuBank_ExceedBankCap();
        }
        _;
    }

    /*///////////////////////
           Functions
    ///////////////////////*/

    /**
     * @notice Constructor que inicializa el contrato bancario V2 con soporte multi-token
     * @dev Establece los límites del banco, configura el oráculo de Chainlink y el token USDC
     *      Hereda de Ownable de OpenZeppelin, estableciendo al deployer como propietario
     * @param _bankCap Capacidad máxima en unidades base que puede almacenar cada usuario por token
     * @param _maxWithdrawAmount Monto máximo en unidades base que se puede retirar en una sola transacción
     * @param _feed Dirección del Price Feed de Chainlink para ETH/USD
     * @param _usdc Dirección del contrato del token USDC
     */
    constructor(uint256 _bankCap, uint256 _maxWithdrawAmount, address _feed, address _usdc)
        Ownable(msg.sender)
    {
        i_bankCap = _bankCap;
        i_maxWithdrawAmount = _maxWithdrawAmount;
        s_feeds = AggregatorV3Interface(_feed);
        i_usdc = IERC20(_usdc);
    }

    /**
     * @notice Función de vista externa para retornar el balance total del contrato en USD
     * @dev Convierte el balance de ETH a USD usando Chainlink y suma el balance de USDC
     *      No considera el balance individual de usuarios, sino el total del contrato
     * @return balance_ El monto total en USD (con decimales de USDC) que posee el contrato
     * @custom:newfeature Función añadida en V2 para transparencia del balance total
     */
    function contractBalanceInUSD() public view returns (uint256 balance_) {
        uint256 convertedUSDAmount = convertEthInUSD(address(this).balance);

        balance_ = convertedUSDAmount + i_usdc.balanceOf(address(this));
    }

    /**
     * @notice Función interna para realizar la conversión de decimales de ETH a USD
     * @dev Multiplica el monto de ETH por el precio del oráculo y ajusta decimales
     *      Fórmula: (ethAmount * precioETH_USD) / DECIMAL_FACTOR
     * @param _ethAmount El monto de ETH en wei a ser convertido
     * @return convertedAmount_ El resultado de la conversión en unidades equivalentes a USD
     * @custom:newfeature Función añadida en V2 para conversión de precios
     */
    function convertEthInUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_ethAmount * chainlinkFeed()) / DECIMAL_FACTOR;
    }

    /**
     * @notice Función interna para consultar el precio de ETH en USD desde Chainlink
     * @dev Implementa todas las validaciones recomendadas por Chainlink:
     *      1. El precio sea positivo (oráculo comprometido)
     *      2. La actualización no sea obsoleta (exceda ORACLE_HEARTBEAT)
     *      3. La consistencia de rondas (answeredInRound >= roundId)
     *      Convierte el int256 retornado por Chainlink a uint256
     * @return ethUSDPrice_ El precio de ETH en USD con 8 decimales (formato Chainlink)
     * @custom:newfeature Función añadida en V2 para integración con Chainlink
     * @custom:security Implementa las mejores prácticas de validación de Chainlink
     */
    function chainlinkFeed() internal view returns (uint256 ethUSDPrice_) {
        (
            uint80 roundId,
            int256 ethUSDPrice,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = s_feeds.latestRoundData();

        if (ethUSDPrice <= 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();
        if (answeredInRound < roundId) revert KipuBank_StalePrice();

        ethUSDPrice_ = uint256(ethUSDPrice);
    }


    /**
     * @notice Función interna privada que registra y emite eventos de depósito
     * @dev Incrementa el contador de depósitos y emite el evento KipuBank_Deposit
     *      Utiliza msg.value como cantidad depositada (solo válido para depósitos de ETH)
     */
    function _depositEtherEvent() private {
        s_depositCounter++;
        emit KipuBank_Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Función interna privada que registra y emite eventos de depósito
     * @dev Incrementa el contador de depósitos y emite el evento KipuBank_Deposit
     *      Utiliza _usdcAmount como cantidad depositada (solo válido para depósitos de token)
     */
    function _depositUSDCEvent(uint256 _usdcAmount) private {
        s_depositCounter++;
        emit KipuBank_Deposit(msg.sender, _usdcAmount);
    }


    /**
     * @notice Función externa payable para depositar ETH en la cuenta del llamador
     * @dev Incrementa el balance de ETH (address(0)) del usuario con msg.value
     *      Valida que la cuenta exista con onlyAccountOwners
     *      Valida que el balance resultante no exceda i_bankCap con exceedBankCapp
     *      Emite un evento KipuBank_Deposit tras el depósito exitoso
     */
    function depositEther() external exceedBankCap(msg.value) payable {
        if(msg.value == 0)  revert KipuBank_NothingToDeposit();
        s_vault[msg.sender][address(0)].balance += msg.value;
        _depositEtherEvent();
    }

    /**
     * @notice Función externa para depositar USDC en la cuenta del llamador
     * @dev Incrementa el balance de USDC del usuario y transfiere tokens al contrato
     *      Utiliza SafeERC20 para transferencia segura desde el usuario al contrato
     *      El usuario debe haber aprobado previamente el contrato para gastar sus USDC
     *      Valida que la cuenta exista y que no se exceda el límite i_bankCap
     *      Emite un evento KipuBank_Deposit tras el depósito exitoso
     * @param _usdcAmount Cantidad de USDC en unidades base a depositar
     */
    function depositUSDC(uint256 _usdcAmount) external exceedBankCap(_usdcAmount) {
        if(_usdcAmount == 0)  revert KipuBank_NothingToDeposit();
        s_vault[msg.sender][address(i_usdc)].balance += _usdcAmount;
        _depositUSDCEvent(_usdcAmount);
        i_usdc.safeTransferFrom(msg.sender, address(this), _usdcAmount);
    }

    /**
     * @notice Función externa para retirar ETH de la cuenta del llamador
     * @dev Implementa el patrón Checks-Effects-Interactions para seguridad:
     *      1. Verifica saldo y límites (modificadores)
     *      2. Reduce el balance interno
     *      3. Incrementa el contador de retiros
     *      4. Emite evento de retiro
     *      5. Transfiere ETH al usuario
     *      Protegida contra reentrada con el modificador noRentrancy
     * @param _amount Cantidad de ETH en wei a retirar de la cuenta
     */
    function withdrawEther(uint256 _amount) external canWithdrawEther(_amount) noRentrancy {
        // Effects: Actualizar todos los estados primero
        s_vault[msg.sender][address(0)].balance -= _amount;
        s_withdrawCounter++;
        emit KipuBank_Withdraw(msg.sender, _amount);

        // Interactions: Llamada externa al final
        (bool sent,) = msg.sender.call{value: _amount}("");
        if (!sent) {
            revert KipuBank_TransferError();
        }
    }

    /**
     * @notice Función externa para retirar USDC de la cuenta del llamador
     * @dev Implementa el patrón Checks-Effects-Interactions para seguridad:
     *      1. Verifica saldo y límites (modificadores)
     *      2. Reduce el balance interno
     *      3. Incrementa contador y emite evento
     *      4. Transfiere USDC al usuario mediante SafeERC20
     *      Protegida contra reentrada con el modificador noRentrancy
     * @param _amount Cantidad de USDC en unidades base a retirar de la cuenta
     */
    function withdrawUSDC(uint256 _amount) external canWithdrawUSDC(_amount) noRentrancy {
        s_vault[msg.sender][address(i_usdc)].balance -= _amount;
        s_withdrawCounter++;
        emit KipuBank_Withdraw(msg.sender, _amount);
        i_usdc.safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Función para actualizar el Price Feed de Chainlink
     * @param _feed La nueva dirección del Price Feed
     * @dev Solo puede ser llamada por el propietario
     * @custom:newfeature
     */
    function setFeeds(address _feed) external onlyOwner {
        s_feeds = AggregatorV3Interface(_feed);

        emit KipuBank_ChainlinkFeedUpdated(_feed);
    }
}
