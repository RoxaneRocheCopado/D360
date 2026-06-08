public with sharing class SDO_SCOM_OrderSummaryGeneratorCtrl {
    
    @AuraEnabled(cacheable=true)
    public static List<Contact> getRelatedBuyers(Id accountId) {
        try {
            if (accountId == null) return new List<Contact>();
            
            return [
                SELECT Id, Name 
                FROM Contact 
                WHERE AccountId = :accountId 
                ORDER BY Name ASC 
                LIMIT 100
            ];
        } catch (Exception e) {
            throw new AuraHandledException('Error loading contacts: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static String generateRandomOrders(Id accountId, Id contactId, Integer numberOfOrders, Integer monthsBack) {
        if (numberOfOrders > 10 || numberOfOrders < 1) {
            throwExceptionToUI('Limit Exceeded: Max 10 orders allowed.');
        }
        if (monthsBack > 10 || monthsBack < 1) {
            throwExceptionToUI('Limit Exceeded: Max 10 months back allowed.');
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // 1. Extract Account Billing Information 
            Account buyerAccount = [
                SELECT Id, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry 
                FROM Account 
                WHERE Id = :accountId 
                LIMIT 1
            ];

            // 2. Resolve the Community User
            List<User> communityUsers = [SELECT Id FROM User WHERE ContactId = :contactId AND IsActive = true LIMIT 1];
            Id buyerUserId = communityUsers.isEmpty() ? UserInfo.getUserId() : communityUsers[0].Id;

            // 3. Find the exact B2B WebStore
            List<WebStore> stores = [SELECT Id FROM WebStore WHERE Name = 'SDO - B2B Commerce Enhanced' LIMIT 1];
            if (stores.isEmpty()) {
                stores = [SELECT Id FROM WebStore LIMIT 1];
            }
            Id webStoreId = stores.isEmpty() ? null : stores[0].Id;

            // 4. Smart Pricebook Resolution (Relaxed constraint for empty SDOs)
            List<PricebookEntry> pbEntries = [
                SELECT Id, Product2Id, UnitPrice, Pricebook2Id 
                FROM PricebookEntry 
                WHERE IsActive = true 
                AND Pricebook2.IsActive = true 
                LIMIT 50
            ];
            
            if (pbEntries.isEmpty()) {
                throwExceptionToUI('Data Error: No active products found in any Pricebook in this org. Please configure products first.');
            }

            Id activePricebookId = pbEntries[0].Pricebook2Id;
            
            // 5. Order Delivery Method Resolution
            List<OrderDeliveryMethod> deliveryMethods = [SELECT Id FROM OrderDeliveryMethod WHERE IsActive = true LIMIT 1];
            Id deliveryMethodId = deliveryMethods.isEmpty() ? null : deliveryMethods[0].Id;

            // 6. Generate Order records
            List<Order> ordersToInsert = new List<Order>();
            for (Integer i = 0; i < numberOfOrders; i++) {
                Date randomPastDate = generateRandomPastDate(monthsBack);
                Datetime orderedDateTime = Datetime.newInstance(randomPastDate.year(), randomPastDate.month(), randomPastDate.day(), 14, 0, 0);

                ordersToInsert.add(new Order(
                    AccountId = accountId,
                    Contact__c = contactId, 
                    OwnerId = buyerUserId,           
                    SalesStoreId = webStoreId,       
                    Pricebook2Id = activePricebookId,
                    Status = 'Draft',
                    EffectiveDate = randomPastDate,
                    OrderedDate = orderedDateTime, 
                    BillingStreet = buyerAccount.BillingStreet, 
                    BillingCity = buyerAccount.BillingCity,
                    BillingState = buyerAccount.BillingState,
                    BillingPostalCode = buyerAccount.BillingPostalCode,
                    BillingCountry = buyerAccount.BillingCountry,
                    SDO_OMS_Is_OMS_Ready__c = true 
                ));
            }
            insert ordersToInsert; 
            
            // 7. Generate Order Delivery Groups
            List<OrderDeliveryGroup> deliveryGroupsToInsert = new List<OrderDeliveryGroup>();
            for (Order ord : ordersToInsert) {
                OrderDeliveryGroup odg = new OrderDeliveryGroup(
                    OrderId = ord.Id,
                    DeliverToName = 'Standard Demo Delivery'
                );
                if (deliveryMethodId != null) {
                    odg.OrderDeliveryMethodId = deliveryMethodId;
                }
                deliveryGroupsToInsert.add(odg);
            }
            insert deliveryGroupsToInsert;

            Map<Id, Id> orderToDeliveryGroupMap = new Map<Id, Id>();
            for (OrderDeliveryGroup odg : deliveryGroupsToInsert) {
                orderToDeliveryGroupMap.put(odg.OrderId, odg.Id);
            }
            
            // 8. Generate OrderItems 
            List<OrderItem> itemsToInsert = new List<OrderItem>();
            for (Order ord : ordersToInsert) {
                Integer numItems = (Integer)Math.floor(Math.random() * 3) + 1;
                for (Integer j = 0; j < numItems; j++) {
                    PricebookEntry pbe = pbEntries[(Integer)Math.floor(Math.random() * pbEntries.size())];
                    
                    Decimal qty = (Integer)Math.floor(Math.random() * 3) + 1; 
                    Decimal totalLineAmount = pbe.UnitPrice * qty;
                    
                    itemsToInsert.add(new OrderItem(
                        OrderId = ord.Id,
                        OrderDeliveryGroupId = orderToDeliveryGroupMap.get(ord.Id), 
                        PricebookEntryId = pbe.Id,
                        Product2Id = pbe.Product2Id,
                        Quantity = qty,
                        UnitPrice = pbe.UnitPrice,
                        ListPrice = pbe.UnitPrice,     
                        Type = 'Order Product',
                        TotalLineAmount = totalLineAmount 
                    ));
                }
            }
            insert itemsToInsert;
            
            // 9. Mass Activation
            for (Order ord : ordersToInsert) {
                ord.Status = 'Activated';
            }
            update ordersToInsert; 
            
            // 10. Native Conversion via ConnectApi (MANAGED)
            Integer successCount = 0;
            for (Order ord : ordersToInsert) {
                ConnectApi.OrderSummaryInputRepresentation input = new ConnectApi.OrderSummaryInputRepresentation();
                input.orderId = ord.Id;
                input.orderLifeCycleType = 'MANAGED'; 
                
                ConnectApi.OrderSummaryOutputRepresentation output = ConnectApi.OrderSummaryCreation.createOrderSummary(input);
                if (output.orderSummaryId != null) successCount++;
            }
            
            return 'Successfully generated ' + successCount + ' Order Summaries for Storefront.';
            
        } catch (Exception e) {
            Database.rollback(sp);
            throwExceptionToUI('Execution Error: ' + e.getMessage());
            return null;
        }
    }
    
    private static Date generateRandomPastDate(Integer monthsBack) {
        return Date.today().addMonths(-(Integer)Math.floor(Math.random() * monthsBack)).addDays(-(Integer)Math.floor(Math.random() * 28));
    }

    private static void throwExceptionToUI(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        throw ex;
    }
}