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
 * @dev No usar en producción
 * @notice TP3 de ETHKipu
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
     * @dev Almacena la información de cada usuario del banco
     * @param balance Saldo actual de la cuenta
     * @param name Nombre del titular de la cuenta
     * @param email Correo electrónico del titular
     * @param exists Flag que indica si la cuenta ha sido creada
     */
    struct Account {
        uint256 balance;
        string name;
        string email;
        bool exists;
    }
    ///@notice mapping to keep track of deposits
    mapping(address user => mapping(address token => Account)) private s_vault;
    ///@notice mutex para controlar la reentrada en las llamadas
    bool private s_locked;
    ///@notice variable inmutable para almacenar el monto máximo de cada retiro
    uint256 public immutable i_maxWithdrawAmount;
    ///@notice variable inmutable para almacenar el monto máximo que puede almacenar el contrato
    uint256 public immutable i_bankCap;
    ///@notice immutable variable to store the USDC address
    IERC20 immutable i_usdc;
    ///@notice contador de cantidad de depositos realizados
    uint256 public s_depositCounter;
    ///@notice contador de cantidad de retiros realizados
    uint256 public s_withdrawCounter;
    ///@notice constant variable to hold Data Feeds Heartbeat
    uint256 constant ORACLE_HEARTBEAT = 3600;
    ///@notice constant variable to gold the decimals factor
    uint256 constant DECIMAL_FACTOR = 1 * 10 ** 20;
    ///@notice constant variable to remove magic number
    uint256 constant ZERO = 0;
    ///@notice variable to store Chainlink Feeds address
    AggregatorV3Interface public s_feeds; //https://docs.chain.link/data-feeds/price-feeds/addresses?page=1&testnetPage=1

    /*///////////////////////
           EVENTS
    ///////////////////////*/
    /**
     * @notice Evento emitido cuando se completa un depósito
     * @param origin Dirección que realizó el depósito
     * @param valor Cantidad depositada en wei
     */
	event KipuBank_Deposit(address origin, uint256 valor);
	/**
     * @notice Evento emitido cuando se completa un retiro
     * @param destination Dirección que recibe el retiro
     * @param valor Cantidad retirada en wei
     */
	event KipuBank_Withdraw(address destination, uint256 valor);
    ///@notice event emitted when the Chainlink Feed is updated
    event KipuBank_ChainlinkFeedUpdated(address feed);

    /*///////////////////////
           ERRORS
    ///////////////////////*/
    ///@notice error emitido cuando alguien diferente al dueño intenta operar el banco
    error KipuBank_DifferentOwner();
    ///@notice error emitido cuando da un error al retirar dinero
    error KipuBank_TransferError();
    ///@notice error emitido cuando se intenta crear una cuenta duplicada
    error KipuBank_AccountAlreadyExists();
    ///@notice error emitido cuando alguien no identificado intenta operar sobre una cuenta
    error KipuBank_AccountNotExists();
    ///@notice error emitido cuando no se tiene saldo suficiente en la cuenta
    error KipuBank_InsufficientFunds(); 
    ///@notice error emitido cuando alguien se intenta extraer más del límite de retiro
    error KipuBank_ExceedWithdrawAmount();
    ///@notice error emitido cuando se intenta depositar más del límite total permitido en el banco
    error KipuBank_ExceedBankCap();
    ///@notice error emitido cuando alguien intenta hacer un ataque de reentrada
    error KipuBank_NoReentrancy();
    ///@notice error emitted when the oracle return is wrong
    error KipuBank_OracleCompromised();
    ///@notice error emitted when the last oracle update is bigger than the heartbeat
    error KipuBank_StalePrice();

    /*///////////////////////
			Modifiers
	///////////////////////*/
    /**
    * @notice este modificador previene los ataques de reentrada
    */
    modifier noRentrancy() {
        if(s_locked) revert KipuBank_NoReentrancy();
        s_locked = true;
        _;
        s_locked = false;
    }
    /**
     * @notice este modificador asegura que solo el dueño del contrato pueda llamar algunas funciones
     */
    /*modifier onlyBankOwner() {
        if(msg.sender != i_contractOwner) revert KipuBank_DifferentOwner();
        _;
    }*/
    
    /**
     * @notice este modificador asegura que solo cuentas existentes puedan operar con el contrato
     */
    modifier onlyAccountOwners() {
        if(!s_vault[msg.sender][address(0)].exists) revert KipuBank_AccountNotExists();
        _;
    }
    
    /**
     * @notice este modificador asegura que no exista una cuenta para poder crearla
     */
    modifier onlyNotExistsAccounts() {
        if(s_vault[msg.sender][address(0)].exists) revert KipuBank_AccountAlreadyExists();
        _;
    }

    /**
		*@notice modificador para verificar si una cuenta tiene saldo suficiente para retirar
		*@dev modificador para verificar si el saldo es correcto para retirar
        *@param _amount monto a transferir
	*/
    modifier canWithdrawEther(uint256 _amount) {
        uint256 userBalance = s_vault[msg.sender][address(0)].balance;
        if(_amount > userBalance) revert KipuBank_InsufficientFunds();
        if(_amount > i_maxWithdrawAmount) revert KipuBank_ExceedWithdrawAmount();
        _;
    }

    /**
		*@notice modificador para verificar si una cuenta tiene saldo suficiente para retirar
		*@dev modificador para verificar si el saldo es correcto para retirar
        *@param _amount monto a transferir
	*/
    modifier canWithdrawUSDC(uint256 _amount) {
        uint256 userBalance = s_vault[msg.sender][address(i_usdc)].balance;
        if(_amount > userBalance) revert KipuBank_InsufficientFunds();
        if(_amount > i_maxWithdrawAmount) revert KipuBank_ExceedWithdrawAmount();
        _;
    }

    /**
		*@notice modificador para controlar que no se exceda el monto total a guardar en el banco
		*@dev modificador para verificar que no se exceda el monto total a guardar en el banco
	*/
    modifier exceedBankCapEther(uint256 _usdcAmount) {
        if(s_vault[msg.sender][address(0)].balance + _usdcAmount > i_bankCap) revert KipuBank_ExceedBankCap();
        _;
    }

    /**
		*@notice modificador para controlar que no se exceda el monto total a guardar en el banco
		*@dev modificador para verificar que no se exceda el monto total a guardar en el banco
	*/
    modifier exceedBankCapUSDC(uint256 _usdcAmount) {
        if(s_vault[msg.sender][address(i_usdc)].balance + _usdcAmount > i_bankCap) revert KipuBank_ExceedBankCap();
        _;
    }

    /*///////////////////////
			Functions
	///////////////////////*/
    /**
    * @notice esta función se llama cuando se crea el contrato
    * @dev esta función se encarga de inicializar el banco y definir el dueño del contrato
    * @param _bankCap es el monto máximo que puede tener el banco
    * @param _maxWithdrawAmount es el monto máximo que se puede retirar en una transacción
    */
    constructor(uint256 _bankCap, uint256 _maxWithdrawAmount, address _feed, address _usdc) Ownable(msg.sender) {
        i_bankCap = _bankCap;
        i_maxWithdrawAmount = _maxWithdrawAmount;
        //i_contractOwner = msg.sender;
        s_feeds = AggregatorV3Interface(_feed);
        i_usdc = IERC20(_usdc);
    }

    /**
     * @notice external view function to return the contract's balance
     * @return balance_ the amount of ETH in the contract
     * @custom:newfeature
     */
    function contractBalanceInUSD() public view returns (uint256 balance_) {
        uint256 convertedUSDAmount = convertEthInUSD(address(this).balance);

        balance_ = convertedUSDAmount + i_usdc.balanceOf(address(this));
    }
    
    /**
     * @notice internal function to perform decimals conversion from ETH to USDC
     * @param _ethAmount the amount of ETH to be converted
     * @return convertedAmount_ the calculations result.
     * @custom:newfeature
     */
    function convertEthInUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_ethAmount * chainlinkFeed()) / DECIMAL_FACTOR;
    }

    /**
     * @notice function to query the USD price of ETH
     * @return ethUSDPrice_ the price provided by the oracle.
     * @dev this is a simplified implementation, and it's not fully best practices compliant
     * @custom:newfeature
     */
    function chainlinkFeed() internal view returns (uint256 ethUSDPrice_) {
        (, int256 ethUSDPrice,, uint256 updatedAt,) = s_feeds.latestRoundData();

        if (ethUSDPrice == 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();

        ethUSDPrice_ = uint256(ethUSDPrice);

        
    }

    /**
		*@notice función para obtener el balance de una cuenta
		*@dev solo el dueño de la cuenta puede obtener el saldo de su cuenta
		*@return uint256 el balance de la cuenta del llamador en wei
	*/
    function getAccountBalanceEther() public view onlyAccountOwners returns (uint256)
    {
        return s_vault[msg.sender][address(0)].balance;
    }

    /**
		*@notice función para obtener el balance de una cuenta
		*@dev solo el dueño de la cuenta puede obtener el saldo de su cuenta
		*@return uint256 el balance de la cuenta del llamador en wei
	*/
    function getAccountBalanceUSDC() public view onlyAccountOwners returns (uint256)
    {
        return s_vault[msg.sender][address(i_usdc)].balance;
    }

    /**
     * @notice Función interna para registrar eventos de depósito
     * @dev Incrementa el contador de depósitos y emite el evento correspondiente
     */
    function _depositEvent() private {
        s_depositCounter++;
        emit KipuBank_Deposit(msg.sender, msg.value);
    }

    /**
		*@notice función para crear una nueva cuenta dentro del banco
		*@dev al crear la cuenta se puede recibir un monto para guardar
		*@param _email dirección de mail del dueño de la cuenta
        *@param _name nombre del dueño de la cuenta
	*/
    function createAccount(string memory _email, string memory _name) public onlyNotExistsAccounts {
        s_vault[msg.sender][address(0)] = Account({
            exists: true,
            balance: 0,
            email: _email,
            name: _name
        });

        s_vault[msg.sender][address(i_usdc)] = Account({
            exists: true,
            balance: 0,
            email: _email,
            name: _name
        });

    }

    /**
		*@notice función que permite depositar ether para una cuenta existente
		*@dev esta función emite un evento ante un deposito correcto, sino revierte el esatod
	*/
    function depositEther() external exceedBankCapEther(ZERO) onlyAccountOwners payable {
        s_vault[msg.sender][address(0)].balance += msg.value;
        _depositEvent();
    }

    /**
     * @notice external function to receive native deposits
     * @notice Emit an event when deposits succeed.
     * @dev after the transaction contract balance should not be bigger than the bank cap
     */
    function depositUSDC(uint256 _usdcAmount) external exceedBankCapEther(_usdcAmount) onlyAccountOwners{
        s_vault[msg.sender][address(i_usdc)].balance += _usdcAmount;
        _depositEvent();
        i_usdc.safeTransferFrom(msg.sender, address(this), _usdcAmount);
    }

    /**
		*@notice Función para retirar saldo de una cuenta USDC
		*@dev en caso exitoso se emite un evento, en caso de error se revierte el estado
        *@param _amount cantidad de ether a retirar de la cuenta
	*/
    function withdrawEther(uint256 _amount) external onlyAccountOwners canWithdrawEther(_amount) noRentrancy {
        s_vault[msg.sender][address(0)].balance -= _amount;
        (bool sent, ) = msg.sender.call{value: _amount}("");
        if(sent){
            s_withdrawCounter++;
            emit KipuBank_Withdraw(msg.sender, _amount);
        }
        else {
            revert KipuBank_TransferError();
        }
    }

    /**
		*@notice Función para retirar saldo de una cuenta USDC
		*@dev en caso exitoso se emite un evento, en caso de error se revierte el estado
        *@param _amount cantidad de USDC a retirar de la cuenta
	*/
    function withdrawUSDC(uint256 _amount) external onlyAccountOwners canWithdrawUSDC(_amount) noRentrancy {
        s_vault[msg.sender][address(i_usdc)].balance -= _amount;
        s_withdrawCounter++;
        emit KipuBank_Withdraw(msg.sender, _amount);
        i_usdc.safeTransfer(msg.sender, _amount);
    }

}