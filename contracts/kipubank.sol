// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title KipuBank
 * @author maugust
 * @dev No usar en producción
 * @notice TP2 de ETHKipu
 * @custom:contact https://github.com/maugust17
 */
contract KipuBank {
    /*///////////////////////
           VARIABLES
    ///////////////////////*/
    struct Account {
        uint256 balance;
        string name;
        string email;
        bool exists;
    }
    ///@notice mapping para almacenar los token de cada cuenta
    mapping(address => Account) s_vault;
    ///@notice mutex para controlar la reentrada en las llamadas
    bool private s_locked;
    ///@notice variable inmutable para almacenar el dueño del contrato
    address public immutable i_contractOwner;
    ///@notice variable inmutable para almacenar el monto máximo de cada retiro
    uint256 public immutable i_maxWithdrawAmount;
    ///@notice variable inmutable para almacenar el monto máximo que puede alamcenar el contrato
    uint256 public immutable i_bankCap;
    ///@notice contador de cantidad de depositos realizados
    uint256 public s_depositCounter;
    ///@notice contador de cantidad de retiros realizados
    uint256 public s_withdrawCounter;

    /*///////////////////////
           EVENTS
    ///////////////////////*/
    ///@notice evento emitido cuando se completa un deposito
	event KipuBank_Deposit(address origin, uint256 valor);
	///@notice evento emitido cuando se completa un retiro
	event KipuBank_Withdraw(address destination, uint256 valor);

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
    error KipuBank_InsuficientFunds(); 
    ///@notice error emitido cuando alguien se intenta extraer más del límite de retiro
    error KipuBank_ExceedWithdrawAmount();
    ///@notice error emitido cuando se intenta depositar más del límite total permitido en el banco
    error KipuBank_ExceedBankCap();
    ///@notice error emitido cuando alguien intenta hacer un ataque de reentrada
    error KipuBank_NoReentrancy();


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
    modifier onlyBankOwner() {
        if(msg.sender != i_contractOwner) revert KipuBank_DifferentOwner();
        _;
    }
    
    /**
     * @notice este modificador asegura que solo cuentas existentes puedan operar con el contrato
     */
    modifier onlyAccountOwners() {
        if(!s_vault[msg.sender].exists) revert KipuBank_AccountNotExists();
        _;
    }
    
    /**
     * @notice este modificador asegura que no exista una cuenta para poder crearla
     */
    modifier onlyNotExistsAccounts() {
        if(s_vault[msg.sender].exists) revert KipuBank_AccountAlreadyExists();
        _;
    }

    /**
		*@notice modificador para verificar si una cuenta tiene saldo suficiente para retirar
		*@dev modificador para verificar si el saldo es correcto para retirar
        *@param _amount monto a transferir
	*/
    modifier canWithdraw(uint256 _amount) {
        uint256 userBalance = s_vault[msg.sender].balance;
        if(_amount > userBalance) revert KipuBank_InsuficientFunds();
        if(_amount > i_maxWithdrawAmount) revert KipuBank_ExceedWithdrawAmount();
        _;
    }

    /**
		*@notice modificador para controlar que no se exceda el monto total a guardar en el banco
		*@dev modificador para verificar que no se exceda el monto total a guardar en el banco
	*/
    modifier exceedBankCap() {
        if(address(this).balance > i_bankCap) revert KipuBank_ExceedBankCap();
        _;
    }

    /*///////////////////////
			Functions
	///////////////////////*/
    /**
    * @notice esta función se llama cuando se crea el contrato
    * @dev esta función se encarga de inicializar el banco y definir el dueño del contrato
    * @param _bankCap es el monto máximo que puede tener el banco
    */
    constructor(uint256 _bankCap, uint256 _maxWithdrawAmount) {
        i_bankCap = _bankCap;
        i_maxWithdrawAmount = _maxWithdrawAmount;
        i_contractOwner = msg.sender;
    }
    
    // funciones para transferir ether directamente al contrato
    // receive() external payable {}
    // fallback() external payable {}  

    /**
		*@notice función para obtener el balance del banco
		*@dev solo el dueño del contrato puede obtener el saldo total
	*/
    function getTotalBankBalance() public view onlyBankOwner returns (uint256) {
        return address(this).balance;
    }

    /**
		*@notice función para obtener el balance de una cuenta
		*@dev solo el dueño de la cuenta puede obtener el saldo de su cuenta
	*/
    function getAccountBalance() public view onlyAccountOwners returns (uint256)
    {
        return s_vault[msg.sender].balance;
    }

    function _depositEvent(address _userAddress) private exceedBankCap {
        s_depositCounter++;
        emit KipuBank_Deposit(msg.sender, msg.value);
    }

    /**
		*@notice función para crear una nueva cuenta dentro del banco
		*@dev al crear la cuenta se puede recibir un monto para guardar
		*@param _email dirección de mail del dueño de la cuenta
        *@param _name nombre del dueño de la cuenta
	*/
    function createAccount(string memory _email, string memory _name) public payable onlyNotExistsAccounts exceedBankCap{
        s_vault[msg.sender] = Account({
            exists: true,
            balance: msg.value,
            email: _email,
            name: _name
        });

        _depositEvent(msg.sender);
        // s_depositCounter++;
        // emit KipuBank_Deposit(msg.sender, msg.value);
    }

    /**
		*@notice función para depositar ether
		*@dev función interna para recibir un monto para guardar
		*@param _userAddress dirección de la cuenta a la que se quiere depositar
	*/
    function deposit(address _userAddress) internal exceedBankCap {
        s_vault[_userAddress].balance += msg.value;

        _depositEvent(msg.sender);
        // s_depositCounter++;
        // emit KipuBank_Deposit(msg.sender, msg.value);
    }

    /**
		*@notice función que permite depositar ether para una cuenta existente
		*@dev esta función emite un evento ante un deposito correcto, sino revierte el esatod
	*/
    function depositIntoMyAccount() public onlyAccountOwners payable {
        deposit(msg.sender);
    }

    /**
		*@notice función para saldo de una cuenta ya creada anteriormente
		*@dev en caso exitoso se emite un evento, en caso de error se revierte el estado
        *@param _amount cantidad de ether a retirar de la cuenta
	*/
    function withdraw(uint256 _amount) onlyAccountOwners canWithdraw(_amount) noRentrancy public {
        s_vault[msg.sender].balance -= _amount;

        (bool sent, ) = msg.sender.call{value: _amount}("");
                
        if(sent){
            s_withdrawCounter++;
            emit KipuBank_Withdraw(msg.sender, _amount);
        }
        else {
            revert KipuBank_TransferError();
        }
    }

}